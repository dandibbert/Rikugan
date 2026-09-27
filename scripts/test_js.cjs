// Node-based tests for Rikugan's injected JavaScript runtimes. The native bridge is mocked so the
// GM API and chrome.* shim logic can be verified without a simulator.
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');

const JS = path.join(__dirname, '..', 'Sources', 'Rikugan', 'Resources', 'JS');
const read = (name) => fs.readFileSync(path.join(JS, name), 'utf8');
let failures = 0;
const tests = [];
const test = (name, fn) => tests.push({ name, fn });

// ---- Minimal DOM-ish environment -----------------------------------------------------------------
function makeEnv(bridge, extra = {}) {
  const listeners = {};
  const appended = [];
  const element = (tag) => ({
    tagName: String(tag).toUpperCase(), attributes: {}, children: [], textContent: '', style: {},
    setAttribute(k, v) { this.attributes[k] = String(v); }, getAttribute(k) { return this.attributes[k]; },
    appendChild(c) { this.children.push(c); appended.push(c); return c; }, sheet: { cssRules: [{}] }, remove() {},
  });
  const documentElement = element('html');
  const head = element('head');
  const document = {
    documentElement, head, body: element('body'), readyState: 'complete', adoptedStyleSheets: [],
    createElement: element, addEventListener() {}, querySelector: () => null, querySelectorAll: () => [],
  };
  const window = {
    webkit: { messageHandlers: { rikugan: { postMessage: (msg) => bridge(msg) } } },
    document, location: { href: 'https://example.com/page', hostname: 'example.com' },
    navigator: { userAgent: 'test' }, console, setTimeout, clearTimeout, setInterval, clearInterval,
    addEventListener: (t, f) => { (listeners[t] = listeners[t] || []).push(f); }, dispatchEvent() {},
    MutationObserver: class { observe() {} disconnect() {} }, CustomEvent: class { constructor(t, o) { this.type = t; Object.assign(this, o); } },
    MouseEvent: class { constructor(t) { this.type = t; } }, TextDecoder, TextEncoder, URL, URLSearchParams, Blob, atob, btoa,
    JSON, Promise, Object, Array, Map, Set, Error, RegExp, String, Number, Math, Date, Uint8Array, ArrayBuffer, DOMParser: class {},
    CSSStyleSheet: class { replaceSync(t) { this.text = t; } }, crypto: { randomUUID: () => 'uuid-' + Math.random() },
    Proxy, Reflect, Symbol, TypeError, isFinite, parseFloat, EventTarget: class {}, Event: class { constructor(t) { this.type = t; } },
    ...extra,
  };
  window.window = window; window.self = window; window.top = window; window.globalThis = window;
  document.defaultView = window;
  return { window, appended };
}

// ---- Userscript runtime --------------------------------------------------------------------------------
function runUserscript(body, config, bridge) {
  const { window, appended } = makeEnv(bridge);
  const cfg = Object.assign({
    id: 'script-1', token: 'tok123', handler: 'rikugan', name: 'Test', grants: ['GM_getValue', 'GM_setValue', 'GM_xmlhttpRequest'],
    values: { counter: '41' }, resources: { txt: { mime: 'text/plain', data: Buffer.from('hello resource').toString('base64') } },
    runAt: 'document-start', frameMode: 'main', include: [], exclude: [], meta: { name: 'Test', version: '1' }, metaStr: '', appVersion: '1.0',
    world: 'content', incognito: false,
  }, config);
  const source = read('UserscriptRuntime.js').replace('/*__RK_CONFIG__*/null', JSON.stringify(cfg)).replace('/*__RK_BODY__*/', body);
  vm.runInNewContext(source, window);
  return { window, appended };
}

test('GM values: preloaded, set, delete, list, listeners', async () => {
  const calls = [];
  const bridge = async (msg) => { calls.push(msg); if (msg.op === 'getAll') return { counter: '41', other: '"x"' }; return null; };
  const { window } = runUserscript(`
    window.result = [];
    window.result.push(GM_getValue('counter'));
    GM_addValueChangeListener('counter', (k, o, n, remote) => window.result.push(['change', k, o, n, remote]));
    GM_setValue('counter', GM_getValue('counter') + 1);
    window.result.push(GM_getValue('counter'));
    GM_setValue('obj', {a: [1, 2]});
    window.result.push(GM_getValue('obj').a[1]);
    window.result.push(GM_getValue('missing', 'dflt'));
    GM_deleteValue('obj');
    window.result.push(GM_listValues().sort().join(','));
    window.result.push(GM_getResourceText('txt'));
    window.result.push(GM_getResourceURL('txt').slice(0, 22));
    window.result.push(typeof unsafeWindow, GM_info.scriptHandler, GM_info.script.name);
  `, {}, bridge);
  await new Promise((r) => setTimeout(r, 10));
  const r = JSON.parse(JSON.stringify(window.result));
  assert.strictEqual(r[0], 41);
  assert.deepStrictEqual(r[1], ['change', 'counter', 41, 42, false]);
  assert.strictEqual(r[2], 42);
  assert.strictEqual(r[3], 2);
  assert.strictEqual(r[4], 'dflt');
  assert.strictEqual(r[5], 'counter');
  assert.strictEqual(r[6], 'hello resource');
  assert.strictEqual(r[7], 'data:text/plain;base64');
  assert.deepStrictEqual(r.slice(8), ['object', 'Rikugan', 'Test']);
  const set = calls.find((c) => c.op === 'setValue' && c.args.key === 'counter');
  assert.strictEqual(set.args.value, '42');
  assert.strictEqual(set.token, 'tok123');
  assert.ok(calls.some((c) => c.op === 'deleteValue' && c.args.key === 'obj'));
});

test('GM remote value change and menu commands dispatch', async () => {
  const bridge = async () => null;
  const { window } = runUserscript(`
    window.hits = [];
    GM_addValueChangeListener('k', (key, o, n, remote) => window.hits.push([n, remote]));
    GM_registerMenuCommand('Do it', () => window.hits.push('menu'));
  `, {}, bridge);
  window['__rikuganGM_tok123']({ type: 'valueChanged', key: 'k', value: '"v"' });
  window['__rikuganGM_tok123']({ type: 'menu', id: '1' });
  assert.deepStrictEqual(JSON.parse(JSON.stringify(window.hits)), [['v', true], 'menu']);
});

test('GM_xmlhttpRequest: callbacks, json response, headers', async () => {
  let request;
  const bridge = async (msg) => {
    if (msg.op === 'xhr') { request = msg.args; return { status: 200, statusText: 'OK', finalUrl: msg.args.url, responseHeaders: 'content-type: application/json', contentType: 'application/json', base64: Buffer.from('{"ok":true}').toString('base64'), size: 11 }; }
    return null;
  };
  const { window } = runUserscript(`
    window.done = new Promise((resolve) => GM_xmlhttpRequest({ url: '/api', method: 'post', data: 'a=1', headers: {'X-T': '1'}, responseType: 'json',
      onload: (r) => resolve([r.status, r.response.ok, r.responseText, r.finalUrl]) }));
  `, {}, bridge);
  const result = JSON.parse(JSON.stringify(await window.done));
  assert.deepStrictEqual(result, [200, true, '{"ok":true}', 'https://example.com/api']);
  assert.strictEqual(request.method, 'POST');
  assert.strictEqual(request.body, 'a=1');
  assert.strictEqual(request.headers['X-T'], '1');
});

test('GM.xmlHttpRequest promise rejects on error; unsupported APIs throw', async () => {
  const bridge = async (msg) => (msg.op === 'xhr' ? { error: 'Blocked by @connect' } : null);
  const { window } = runUserscript(`
    window.p = GM.xmlHttpRequest({ url: 'https://evil.test/' }).then(() => 'ok', (e) => 'rejected:' + e.message);
    try { GM_cookie.list({}); window.cookie = 'no'; } catch (e) { window.cookie = e.message; }
  `, {}, bridge);
  assert.strictEqual(await window.p, 'rejected:Blocked by @connect');
  assert.match(window.cookie, /Unsupported API/);
});

test('Sub-frame variant checks include/exclude regex', async () => {
  let ran = false;
  const bridge = async () => null;
  const env = makeEnv(bridge);
  env.window.top = {}; // not top
  const cfg = { id: 's', token: 't', handler: 'rikugan', name: 'F', grants: [], values: {}, resources: {}, runAt: 'document-start', frameMode: 'sub',
    include: [['^https://example\\.com/.*$', '']], exclude: [['^https://example\\.com/skip', '']], meta: {}, metaStr: '', appVersion: '1', world: 'page' };
  const src = read('UserscriptRuntime.js').replace('/*__RK_CONFIG__*/null', JSON.stringify(cfg)).replace('/*__RK_BODY__*/', 'window.ran = true;');
  vm.runInNewContext(src, env.window);
  ran = env.window.ran;
  assert.strictEqual(ran, true);
});

// ---- Chrome runtime --------------------------------------------------------------------------------------
function runChrome(ctx, bridge, extraCfg = {}) {
  const { window } = makeEnv(bridge);
  window.location.href = ctx === 'content' ? 'https://example.com/' : 'chrome-extension://abcdefghijklmnopabcdefghijklmnop/popup.html';
  window.fetch = async () => ({ ok: true });
  window.Response = class { constructor(body, init) { this.body = body; this.init = init; } };
  const cfg = Object.assign({
    extId: 'abcdefghijklmnopabcdefghijklmnop', ctx, handler: 'rikugan', baseURL: 'chrome-extension://abcdefghijklmnopabcdefghijklmnop/',
    manifest: { name: 'T', version: '1', manifest_version: 3 }, messages: { greet: { message: 'Hi $who$ ($1)', placeholders: { who: { content: '$1' } } } },
    uiLanguage: 'zh-CN', uiLocale: 'zh_CN', acceptLanguages: ['zh-CN', 'en'], unsupported: ['debugger', 'webRequest'],
  }, extraCfg);
  const src = read('ChromeRuntime.js').replace('/*__RK_CHROME_CONFIG__*/null', JSON.stringify(cfg));
  vm.runInNewContext(src, window);
  return window;
}

test('chrome.storage get/set/defaults and onChanged', async () => {
  const store = {};
  const bridge = async (msg) => {
    const a = msg.args;
    if (msg.api === 'storage.set') { Object.assign(store, a.items); return null; }
    if (msg.api === 'storage.get') { const out = {}; for (const k of (a.keys || Object.keys(store))) if (k in store) out[k] = store[k]; return out; }
    return null;
  };
  const w = runChrome('background', bridge);
  await w.chrome.storage.local.set({ a: 1, b: { c: [true] } });
  const got = await w.chrome.storage.local.get(['a', 'b']);
  assert.deepStrictEqual(JSON.parse(JSON.stringify(got)), { a: 1, b: { c: [true] } });
  const withDefaults = await w.chrome.storage.local.get({ a: 0, z: 'dflt' });
  assert.deepStrictEqual(JSON.parse(JSON.stringify(withDefaults)), { a: 1, z: 'dflt' });
  const seen = [];
  w.chrome.storage.onChanged.addListener((changes, area) => seen.push([area, changes.a.newValue, changes.a.oldValue]));
  w.__rikuganChrome.dispatch('storage.local.onChanged', [{ a: { oldValue: '1', newValue: '2' } }]);
  assert.deepStrictEqual(seen, [['local', 2, 1]]);
  await new Promise((resolve) => w.chrome.storage.local.get('a', (r) => { assert.strictEqual(r.a, 1); resolve(); }));
});

test('chrome.runtime messaging: sendMessage + deliverMessage async response', async () => {
  const bridge = async (msg) => (msg.api === 'runtime.sendMessage' ? { echoed: msg.args.message } : null);
  const w = runChrome('content', bridge);
  const r = await w.chrome.runtime.sendMessage({ hello: 1 });
  assert.deepStrictEqual(r, { echoed: { hello: 1 } });
  const bg = runChrome('background', async () => null);
  bg.chrome.runtime.onMessage.addListener((m, sender, sendResponse) => { setTimeout(() => sendResponse({ got: m.q, from: sender.id }), 5); return true; });
  const response = await bg.__rikuganChrome.deliverMessage({ q: 'x' }, { id: 'abc' });
  assert.deepStrictEqual(JSON.parse(JSON.stringify(response)), { response: { got: 'x', from: 'abc' }, has: true });
  const bg2 = runChrome('background', async () => null);
  bg2.chrome.runtime.onMessage.addListener(async (m) => ({ promised: m }));
  const r2 = await bg2.__rikuganChrome.deliverMessage(7, {});
  assert.strictEqual(r2.response.promised, 7);
  const bg3 = runChrome('background', async () => null);
  assert.strictEqual((await bg3.__rikuganChrome.deliverMessage(1, {})).none, true);
});

test('chrome callbacks set runtime.lastError; unsupported APIs never undefined', async () => {
  const bridge = async (msg) => { if (msg.api === 'tabs.get') throw new Error('No tab with id: 99'); return null; };
  const w = runChrome('background', bridge);
  const err = await new Promise((resolve) => w.chrome.tabs.get(99, () => resolve(w.chrome.runtime.lastError && w.chrome.runtime.lastError.message)));
  assert.strictEqual(err, 'No tab with id: 99');
  assert.strictEqual(w.chrome.runtime.lastError, undefined);
  await assert.rejects(() => w.chrome.debugger.attach({ tabId: 1 }, '1.3'), /Unsupported API: chrome.debugger.attach/);
  await assert.rejects(() => w.chrome.tabs.move(1, {}), /Unsupported API/);
  assert.strictEqual(typeof w.chrome.sidePanelDoesNotExist.open, 'function');
  assert.strictEqual(typeof w.chrome.webRequest.onBeforeRequest.addListener, 'function');
  const content = runChrome('content', async () => null);
  assert.strictEqual(content.chrome.tabs, undefined, 'content scripts must not see chrome.tabs (matches Chrome)');
});

test('chrome.i18n getMessage with placeholders; runtime.getURL', () => {
  const w = runChrome('page', async () => null);
  assert.strictEqual(w.chrome.i18n.getMessage('greet', ['Bob']), 'Hi Bob (Bob)');
  assert.strictEqual(w.chrome.i18n.getMessage('@@extension_id'), 'abcdefghijklmnopabcdefghijklmnop');
  assert.strictEqual(w.chrome.runtime.getURL('/img/a.png'), 'chrome-extension://abcdefghijklmnopabcdefghijklmnop/img/a.png');
  assert.strictEqual(w.browser.runtime.id, 'abcdefghijklmnopabcdefghijklmnop');
});

test('chrome.runtime.connect ports route both ways', async () => {
  const sent = [];
  const w = runChrome('content', async (msg) => { sent.push(msg); return null; });
  const port = w.chrome.runtime.connect({ name: 'p1' });
  const got = [];
  port.onMessage.addListener((m) => got.push(m));
  port.postMessage({ a: 1 });
  await new Promise((r) => setTimeout(r, 5));
  const open = sent.find((m) => m.api === 'runtime.connect');
  assert.strictEqual(open.args.name, 'p1');
  const post = sent.find((m) => m.api === 'port.post');
  assert.strictEqual(post.args.portId, open.args.portId);
  w.__rikuganChrome.portEvent(open.args.portId, 'message', { b: 2 });
  assert.deepStrictEqual(got, [{ b: 2 }]);
  const bg = runChrome('background', async () => null);
  let connected;
  bg.chrome.runtime.onConnect.addListener((p) => { connected = p; });
  assert.strictEqual(bg.__rikuganChrome.openPort('pid', 'n', { id: 'x' }), true);
  assert.strictEqual(connected.name, 'n');
});

test('scripting.executeScript serialises func and args', async () => {
  let payload;
  const w = runChrome('background', async (msg) => { payload = msg.args; return [{ frameId: 0, result: 3 }]; });
  const r = await w.chrome.scripting.executeScript({ target: { tabId: 1 }, func: (a, b) => a + b, args: [1, 2] });
  assert.strictEqual(r[0].result, 3);
  assert.match(payload.func, /a \+ b/);
  assert.deepStrictEqual(payload.args, [1, 2]);
});

// ---- Compatibility matrix is verified against the implementation -------------------------------------
test('chrome-api-matrix.json matches the JS shim and the native bridge', () => {
  const matrix = JSON.parse(read('chrome-api-matrix.json')).namespaces;
  const swift = fs.readFileSync(path.join(__dirname, '..', 'Sources', 'Rikugan', 'Extensions', 'ChromeAPIBridge.swift'), 'utf8');
  const w = runChrome('background', async () => null);
  const prefixDispatched = new Set(['action', 'cookies', 'downloads', 'declarativeNetRequest', 'alarms']);
  const problems = [];
  for (const [ns, spec] of Object.entries(matrix)) {
    const nsObj = w.chrome[ns];
    if (nsObj === undefined) { problems.push(`chrome.${ns} is undefined`); continue; }
    for (const [method, entry] of Object.entries(spec.methods || {})) {
      const [level, , jsOnly] = entry;
      let value = nsObj;
      for (const part of method.split('.')) value = value == null ? undefined : value[part];
      const isEvent = /^on[A-Z]/.test(method.split('.').pop());
      if (level === 'Unsupported') {
        if (!value || !value.__rikuganUnsupported) problems.push(`${ns}.${method} is marked Unsupported but is implemented / not flagged`);
        continue;
      }
      if (value === undefined) { problems.push(`${ns}.${method} missing`); continue; }
      if (value.__rikuganUnsupported) { problems.push(`${ns}.${method} is marked ${level} but resolves to an Unsupported stub`); continue; }
      if (isEvent) { if (typeof value.addListener !== 'function') problems.push(`${ns}.${method} is not an event`); continue; }
      if (typeof value !== 'function') { problems.push(`${ns}.${method} is not a function`); continue; }
      if (jsOnly) continue;
      const bare = method.includes('.') ? method.split('.').pop() : method;
      const swiftName = ns === 'storage' ? `"storage.${bare}"` : `"${ns}.${method}"`;
      const found = swift.includes(swiftName) || (prefixDispatched.has(ns) && swift.includes(`"${method}"`)) ||
        (prefixDispatched.has(ns) && new RegExp(`case [^\n]*"${method}"`).test(swift));
      if (!found) problems.push(`${ns}.${method} has no native implementation in ChromeAPIBridge.swift`);
    }
  }
  assert.deepStrictEqual(problems, []);
});

test('page scripts parse', () => {
  for (const f of ['PageTools.js', 'PageHooks.js']) new vm.Script(read(f), { filename: f });
});

(async () => {
  for (const t of tests) {
    try { await t.fn(); console.log('ok   -', t.name); }
    catch (e) { failures++; console.log('FAIL -', t.name); console.log(e && e.stack || e); }
  }
  console.log(`${tests.length - failures}/${tests.length} JS tests passed`);
  process.exit(failures ? 1 : 0);
})();
