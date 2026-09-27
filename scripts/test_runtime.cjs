const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const template = fs.readFileSync('Rikugan/Resources/UserscriptRuntime.js', 'utf8');
function run(url, override = {}, source = 'globalThis.didRun = true;', extras = {}) {
  const config = {id: 'test', name: 'Test', version: '1', handler: 'test', matches: ['https://*.example.com/*'], includes: [], excludes: [], excludeMatches: [], grants: [], runAt: 'document-end', storage: {}, ...override};
  const calls = [];
  const sandbox = {location: new URL(url), URL, console, setTimeout, JSON, window: {webkit: {messageHandlers: {test: {postMessage: body => { calls.push(body); return Promise.resolve(true); }}}}}, ...extras};
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
const page = { title: 'Hello', count: 1 };
const documentElement = {
  attrs: {},
  appendChild(el) { vm.runInNewContext(el.textContent, { window: page, document: { documentElement }, JSON }); },
  setAttribute(name, value) { this.attrs[name] = value; },
  getAttribute(name) { return Object.prototype.hasOwnProperty.call(this.attrs, name) ? this.attrs[name] : null; },
  removeAttribute(name) { delete this.attrs[name]; }
};
const bridged = run('https://example.com/', { isolated: true }, "unsafeWindow.count = 4; globalThis.read = unsafeWindow.title; globalThis.count = unsafeWindow.count;", {
  document: { createElement() { return { textContent: '', remove() {} }; }, documentElement }
});
assert.equal(bridged.sandbox.read, 'Hello');
assert.equal(bridged.sandbox.count, 4);
assert.equal(page.count, 4);
const menu = run('https://example.com/', { grants: ['none'], isolated: false }, "globalThis.menu = GM_registerMenuCommand('Hi', function () {});");
assert.equal(menu.calls[0].operation, 'registerMenuCommand');
assert.equal(typeof menu.sandbox.menu, 'string');
const xhr = run('https://example.com/', { grants: ['GM_xmlhttpRequest'] }, "const req = GM_xmlhttpRequest({url:'https://example.com/a', onabort(){ globalThis.aborted = true; }}); req.abort();");
assert.ok(xhr.calls.some(call => call.operation === 'xmlHttpRequest'));
assert.ok(xhr.calls.some(call => call.operation === 'abortRequest'));
assert.equal(xhr.sandbox.aborted, true);
const progress = run('https://example.com/', { grants: ['GM_xmlhttpRequest'] }, "GM_xmlhttpRequest({url:'https://example.com/a', onprogress(event){ globalThis.loaded = event.loaded; globalThis.total = event.total; }});");
const progressID = progress.calls.find(call => call.operation === 'xmlHttpRequest').args.id;
progress.sandbox.__rikuganXHREvent({ id: progressID, loaded: 3, total: 9 });
assert.equal(progress.sandbox.loaded, 3);
assert.equal(progress.sandbox.total, 9);
const spa = run('https://example.com/a', {}, 'globalThis.runs = (globalThis.runs || 0) + 1;');
assert.equal(spa.sandbox.runs, 1);
spa.sandbox.location = new URL('https://example.com/b');
spa.sandbox.__rikuganOnURLChange();
assert.equal(spa.sandbox.runs, 2);
spa.sandbox.__rikuganOnURLChange();
assert.equal(spa.sandbox.runs, 2);
const framed = run('https://example.com/a', { noFrames: true }, 'globalThis.didRun = true;', { window: { top: {}, webkit: { messageHandlers: {} } } });
assert.equal(framed.sandbox.didRun, undefined);
const listener = run('https://example.com/', { grants: ['GM_setValue', 'GM_addValueChangeListener'] }, "GM_addValueChangeListener('x', function (name, oldValue, newValue, remote) { globalThis.seen = [name, oldValue, newValue, remote]; }); GM_setValue('x', 2);");
assert.equal(listener.sandbox.seen[0], 'x');
assert.equal(listener.sandbox.seen[1], undefined);
assert.equal(listener.sandbox.seen[2], 2);
assert.equal(listener.sandbox.seen[3], false);
const domPage = { document: { querySelector(selector) { return { textContent: 'Ad:' + selector }; } } };
const domElement = {
  attrs: {},
  appendChild(el) { vm.runInNewContext(el.textContent, { window: domPage, document: { documentElement: domElement }, JSON }); },
  setAttribute(name, value) { this.attrs[name] = value; },
  getAttribute(name) { return Object.prototype.hasOwnProperty.call(this.attrs, name) ? this.attrs[name] : null; },
  removeAttribute(name) { delete this.attrs[name]; }
};
const dom = run('https://example.com/', { isolated: true }, "globalThis.got = unsafeWindow.document.querySelector('div.ad').textContent;", {
  document: { createElement() { return { textContent: '', remove() {} }; }, documentElement: domElement }
});
assert.equal(dom.sandbox.got, 'Ad:div.ad');
const body = run('https://example.com/a', { runAt: 'document-body' });
assert.equal(body.sandbox.didRun, true);
console.log('PASS: userscript runtime URL guards, grants, resources, unsafeWindow DOM bridge, menu, xhr and listeners');

