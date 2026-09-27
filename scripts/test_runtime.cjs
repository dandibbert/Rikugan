const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const template = fs.readFileSync('Rikugan/Resources/UserscriptRuntime.js', 'utf8');
function run(url, override = {}, source = 'globalThis.didRun = true;') {
  const config = {id: 'test', name: 'Test', version: '1', handler: 'test', matches: ['https://*.example.com/*'], includes: [], excludes: [], excludeMatches: [], grants: [], runAt: 'document-end', storage: {}, ...override};
  const calls = [];
  const nativeStorage = new Map(Object.entries(config.storage));
  const bridge = body => {
    calls.push(body);
    const {operation, args} = body;
    if (operation === 'getValue') return Promise.resolve({exists: nativeStorage.has(args.key), value: nativeStorage.get(args.key) ?? null});
    if (operation === 'setValue') nativeStorage.set(args.key, args.value);
    if (operation === 'deleteValue') nativeStorage.delete(args.key);
    if (operation === 'listValues') return Promise.resolve([...nativeStorage.keys()]);
    return Promise.resolve(true);
  };
  const sandbox = {location: new URL(url), URL, console, setTimeout, document: {body: {}, readyState: 'complete'}, window: {webkit: {messageHandlers: {test: {postMessage: bridge}}}}};
  const script = template.replace('/*__CONFIG__*/', JSON.stringify(config)).replace('/*__SOURCE__*/', source);
  new vm.Script(script).runInNewContext(sandbox);
  return {sandbox, calls};
}
assert.equal(run('https://example.com/a').sandbox.didRun, true);
assert.equal(run('https://a.example.com/a?x=1#hash').sandbox.didRun, true);
assert.equal(run('https://example.com.evil.test/a').sandbox.didRun, undefined);
assert.equal(run('http://example.com/a').sandbox.didRun, undefined);
assert.equal(run('file:///tmp/a', {matches: ['<all_urls>']}).sandbox.didRun, undefined);
assert.equal(run('https://example.com/private/a', {excludeMatches: ['https://example.com/private/*']}).sandbox.didRun, undefined);
assert.equal(run('http://127.0.0.1:8765/', {matches: ['http://127.0.0.1/*']}).sandbox.didRun, true);
const storage = run('https://example.com/', {grants: ['GM_getValue', 'GM_setValue'], storage: {x: 1}}, "globalThis.before = GM_getValue('x'); GM_setValue('x', 2); globalThis.after = GM_getValue('x'); globalThis.unauthorized = typeof GM_xmlhttpRequest;");
assert.equal(storage.sandbox.before, 1); assert.equal(storage.sandbox.after, 2);
assert.equal(storage.sandbox.unauthorized, 'undefined');
assert.equal(storage.calls[0].operation, 'setValue');
console.log('PASS: userscript runtime syntax, URL guards, exclusions, grants and synchronous storage');
async function testAsyncStorage() {
  const {sandbox} = run('https://example.com/', {grants: ['GM.getValue', 'GM.setValue', 'GM.deleteValue', 'GM.listValues'], storage: {nullable: null}}, `
    globalThis.result = (async () => {
      const nullable = await GM.getValue('nullable', 'fallback');
      const missing = await GM.getValue('missing', 'fallback');
      await GM.setValue('answer', 42);
      const answer = await GM.getValue('answer');
      await GM.deleteValue('nullable');
      return [nullable, missing, answer, (await GM.listValues()).length];
    })();
  `);
  assert.deepEqual(Array.from(await sandbox.result), [null, 'fallback', 42, 1]);
  console.log('PASS: asynchronous GM storage preserves null and distinguishes missing values');
}
testAsyncStorage().catch(error => { console.error(error); process.exitCode = 1; });
const resources = run('https://example.com/', {
  grants: ['GM_getResourceText', 'GM_getResourceURL'],
  resources: { style: { text: 'body{}', url: 'data:text/css;base64,Ym9keXt9' } }
}, "globalThis.text = GM_getResourceText('style'); globalThis.href = GM_getResourceURL('style'); globalThis.missing = String(GM_getResourceText('nope'));");
assert.equal(resources.sandbox.text, 'body{}');
assert.equal(resources.sandbox.href, 'data:text/css;base64,Ym9keXt9');
assert.equal(resources.sandbox.missing, 'undefined');
const isolated = run('https://example.com/', { isolated: true }, 'try { unsafeWindow.document; globalThis.leaked = true; } catch (error) { globalThis.partial = String(error.message); }');
assert.equal(isolated.sandbox.leaked, undefined);
assert.match(isolated.sandbox.partial, /Partial/);
const body = run('https://example.com/a', { runAt: 'document-body' });
assert.equal(body.sandbox.didRun, true);
console.log('PASS: userscript runtime syntax, URL guards, exclusions, grants, resources and partial unsafeWindow');

