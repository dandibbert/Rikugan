const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const template = fs.readFileSync('Rikugan/Resources/UserscriptRuntime.js', 'utf8');
const domains = new Map();
const tick = () => new Promise(resolve => setImmediate(resolve));

function page(domain, id = 'probe') {
  const bucket = domain + '/' + id;
  if (!domains.has(bucket)) domains.set(bucket, {values: new Map(), revision: 0, clients: new Map()});
  const state = domains.get(bucket);
  let sandbox;
  const bridge = ({operation, args, client}) => {
    if (operation === 'observeStorage') {
      state.clients.set(client, sandbox);
      return Promise.resolve({values: Object.fromEntries(state.values), revision: state.revision});
    }
    if (operation === 'getValue') return Promise.resolve({exists: state.values.has(args.key), value: state.values.get(args.key) ?? null});
    if (operation === 'listValues') return Promise.resolve([...state.values.keys()]);
    assert.ok(['setValue', 'deleteValue'].includes(operation));
    const oldExists = state.values.has(args.key), oldValue = state.values.get(args.key);
    const newExists = operation !== 'deleteValue';
    if (newExists) state.values.set(args.key, args.value); else state.values.delete(args.key);
    if (oldExists === newExists && JSON.stringify(oldValue) === JSON.stringify(state.values.get(args.key))) {
      return Promise.resolve({changed: false, values: Object.fromEntries(state.values), revision: state.revision});
    }
    const event = {changed: true, key: args.key, oldValue, oldExists, newValue: args.value, newExists, writer: client, revision: ++state.revision};
    for (const [clientID, context] of state.clients) setImmediate(() => context.__rikuganStorageChange(clientID, event));
    return Promise.resolve(event);
  };
  const config = {id, name: id, isolated: true, handler: 'test', matches: ['https://example.com/*'], includes: [], excludes: [], excludeMatches: [],
    grants: ['GM_getValue', 'GM.getValue', 'GM_setValue', 'GM.setValue', 'GM_deleteValue', 'GM.deleteValue', 'GM_listValues', 'GM_addValueChangeListener', 'GM_removeValueChangeListener'], runAt: 'document-end', storage: {}};
  sandbox = vm.createContext({location: new URL('https://example.com/'), URL, console, setTimeout, btoa, atob, document: {body: {}},
    window: {webkit: {messageHandlers: {test: {postMessage: bridge}}}}});
  new vm.Script(template.replace('/*__CONFIG__*/', JSON.stringify(config)).replace('/*__SOURCE__*/', `
    globalThis.events = [];
    globalThis.api = {read: GM_getValue, set: GM.setValue, setSync: GM_setValue, del: GM.deleteValue, listen: GM_addValueChangeListener,
      remove: GM_removeValueChangeListener, list: GM_listValues};
    globalThis.listenerID = GM_addValueChangeListener('key', (...args) => events.push(args));
  `)).runInContext(sandbox);
  return sandbox;
}

(async () => {
  const a = page('normal'), b = page('normal'), privatePage = page('private'), otherScript = page('normal', 'other');
  await tick();
  await a.api.set('key', null); await tick();
  assert.equal(a.events.length, 1); assert.equal(b.events.length, 1);
  assert.equal(a.events[0][1], undefined); assert.equal(a.events[0][2], null); assert.equal(a.events[0][3], false);
  assert.equal(b.events[0][3], true); assert.equal(b.api.read('key', 'fallback'), null);
  assert.equal(privatePage.api.read('key', 'private'), 'private');
  assert.equal(otherScript.api.read('key', 'other'), 'other');
  const first = a.api.set('key', 1), second = a.api.set('key', 2);
  assert.equal(a.api.read('key'), 2, 'Read-your-writes must reflect the latest queued local write');
  await Promise.all([first, second]); await tick();
  assert.equal(b.api.read('key'), 2); assert.equal(a.api.read('key'), 2);
  await b.api.del('key'); await tick();
  assert.equal(a.events.at(-1)[2], undefined); assert.equal(a.events.at(-1)[3], true);
  assert.equal(b.events.at(-1)[3], false); assert.equal(a.api.read('key', 'missing'), 'missing');
  b.api.remove(b.listenerID);
  const oldCount = b.events.length;
  await a.api.set('key', 9); await tick();
  assert.equal(b.events.length, oldCount); assert.equal(b.api.read('key'), 9, 'Removing a listener must not stop the value mirror');
  const ownCount = a.events.length;
  await a.api.set('key', 9); await tick();
  assert.equal(a.events.length, ownCount, 'Identical writes do not emit changes');
  await a.api.set('__proto__', {safe: true}); await tick();
  assert.deepEqual(JSON.parse(JSON.stringify(b.api.read('__proto__'))), {safe: true});
  assert.equal(privatePage.events.length, 0); assert.equal(otherScript.events.length, 0);
  await a.api.set('undefined', undefined); await tick();
  assert.equal(b.api.list().includes('undefined'), true); assert.equal(b.api.read('undefined', 'fallback'), undefined);
  const special = vm.runInContext(`({nan: NaN, inf: Infinity, neg: -Infinity, minusZero: -0, big: 9007199254740993n,
    date: new Date('2026-09-27T00:00:00Z'), regexp: /rikugan/gi, map: new Map([['x', 1]]), set: new Set(['a', 'b']),
    bytes: new Uint16Array([1, 65535]), nested: {__proto__: null, safe: 'yes'}})`, a);
  await a.api.set('special', special); await tick();
  const restored = b.api.read('special');
  assert.equal(Number.isNaN(restored.nan), true); assert.equal(restored.inf, Infinity); assert.equal(restored.neg, -Infinity); assert.equal(Object.is(restored.minusZero, -0), true);
  assert.equal(String(restored.big), '9007199254740993'); assert.equal(Object.prototype.toString.call(restored.date), '[object Date]');
  assert.equal(restored.date.toISOString(), '2026-09-27T00:00:00.000Z'); assert.equal(String(restored.regexp), '/rikugan/gi');
  assert.equal(restored.map.get('x'), 1); assert.deepEqual(Array.from(restored.set), ['a', 'b']); assert.deepEqual(Array.from(restored.bytes), [1, 65535]);
  assert.equal(restored.nested.safe, 'yes');
  const cyclic = {}; cyclic.self = cyclic;
  assert.throws(() => a.api.set('cycle', cyclic), /cyclic/);
  assert.throws(() => a.api.set('function', () => {}), /function/);
  console.log('PASS: GM cross-page mirror, local/remote events, null vs deletion, listeners, pending writes and private/script isolation');
})().catch(error => { console.error(error); process.exitCode = 1; });
