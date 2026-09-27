const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const template = fs.readFileSync('Rikugan/Resources/UserscriptRuntime.js', 'utf8');
function run(url, override = {}, source = 'globalThis.didRun = true;', extras = {}) {
  const manualXHR = !!override.manualXHR;
  const configOverride = {...override};
  delete configOverride.manualXHR;
  const config = {id: 'test', name: 'Test', version: '1', handler: 'test', matches: ['https://*.example.com/*'], includes: [], excludes: [], excludeMatches: [], grants: [], runAt: 'document-end', storage: {}, ...configOverride};
  const calls = [];
  const resolvers = [];
  const sandbox = {location: new URL(url), URL, URLSearchParams, console, setTimeout, JSON, FormData, Blob, File, TextEncoder, Uint8Array, ArrayBuffer, ReadableStream, btoa, atob, window: {webkit: {messageHandlers: {test: {postMessage: body => { calls.push(body); return manualXHR ? new Promise(resolve => resolvers.push(resolve)) : Promise.resolve(true); }}}}}, ...extras};
  const script = template.replace('/*__CONFIG__*/', JSON.stringify(config)).replace('/*__SOURCE__*/', source);
  new vm.Script(script).runInNewContext(sandbox);
  return {sandbox, calls, resolvers};
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
const topFrame = run('https://example.com/a', { noFrames: true }, 'globalThis.didRun = true;');
assert.equal(topFrame.sandbox.didRun, true);
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
const node = { textContent: 'old', attrs: { id: 'p1' }, getAttribute(name) { return this.attrs[name]; } };
const domDoc = { title: 'T', querySelector() { return node; } };
const nodePage = { document: domDoc };
const domHost = {
  attrs: {},
  appendChild(el) { vm.runInNewContext(el.textContent, { window: nodePage, document: { documentElement: domHost }, JSON }); },
  setAttribute(name, value) { this.attrs[name] = value; },
  getAttribute(name) { return Object.prototype.hasOwnProperty.call(this.attrs, name) ? this.attrs[name] : null; },
  removeAttribute(name) { delete this.attrs[name]; }
};
const domOps = run('https://example.com/', { isolated: true }, "const el = unsafeWindow.document.querySelector('p'); globalThis.before = el.textContent; el.textContent = 'set-ok'; globalThis.after = el.textContent; globalThis.attr = el.getAttribute('id'); globalThis.title = unsafeWindow.document.title;", {
  document: { createElement() { return { textContent: '', remove() {} }; }, documentElement: domHost }
});
assert.equal(domOps.sandbox.before, 'old');
assert.equal(domOps.sandbox.after, 'set-ok');
assert.equal(node.textContent, 'set-ok');
assert.equal(domOps.sandbox.attr, 'p1');
assert.equal(domOps.sandbox.title, 'T');
const fnDoc = { title: 'T', querySelector() { return fnNode; } };
const fnNode = {
  listeners: {},
  addEventListener(type, fn) { this.listeners[type] = fn; }
};
const fnPage = { document: fnDoc, someHook: null };
const fnHost = {
  attrs: {},
  setAttribute(name, value) { this.attrs[name] = value; },
  getAttribute(name) { return Object.prototype.hasOwnProperty.call(this.attrs, name) ? this.attrs[name] : null; },
  removeAttribute(name) { delete this.attrs[name]; }
};
const fnContext = { window: fnPage, document: { documentElement: fnHost }, JSON };
fnContext.eval = code => vm.runInContext(code, fnContext);
vm.createContext(fnContext);
fnHost.appendChild = el => { vm.runInContext(el.textContent, fnContext); };
const fnDocument = { createElement() { return { textContent: '', remove() {} }; }, documentElement: fnHost };
const pureFn = run('https://example.com/', { isolated: true }, "unsafeWindow.someHook = function () { return 7; }; globalThis.out = unsafeWindow.someHook();", { document: fnDocument });
assert.equal(pureFn.sandbox.out, 7);
assert.equal(fnPage.someHook(), 7);
fnHost.__rgInvoke = () => { throw new Error('iso'); };
const closedFn = run('https://example.com/', { isolated: true }, "let n = 1; unsafeWindow.someHook = function () { n += 1; return n; }; globalThis.first = unsafeWindow.someHook(); globalThis.second = unsafeWindow.someHook();", { document: fnDocument });
assert.equal(closedFn.sandbox.first, 2);
assert.equal(closedFn.sandbox.second, 3);
assert.equal(fnPage.someHook(), 4);
assert.match(String(fnHost.__rgInvoke), /iso/);
const constFn = run('https://example.com/', { isolated: true }, "const box = { a: 1, b: 'x' }; unsafeWindow.someHook = function () { return box; }; globalThis.got = unsafeWindow.someHook();", { document: fnDocument });
assert.deepEqual(JSON.parse(JSON.stringify(constFn.sandbox.got)), { a: 1, b: 'x' });
assert.deepEqual(JSON.parse(JSON.stringify(fnPage.someHook())), { a: 1, b: 'x' });
const objectReturn = run('https://example.com/', { isolated: true }, "let marker = { n: 1, inc() { this.n += 1; return { n: this.n, label: 'ok' }; } }; unsafeWindow.someHook = function () { return marker.inc(); }; globalThis.got = unsafeWindow.someHook();", { document: fnDocument });
assert.deepEqual(JSON.parse(JSON.stringify(objectReturn.sandbox.got)), { n: 2, label: 'ok' });
assert.deepEqual(JSON.parse(JSON.stringify(fnPage.someHook())), { n: 3, label: 'ok' });
assert.equal(template.includes('rikugan-bridge'), false);
const objectFn = run('https://example.com/', { isolated: true }, "let marker = { n: 1, inc() { this.n += 1; return this.n; } }; unsafeWindow.someHook = function () { return marker.inc(); }; globalThis.via = unsafeWindow.someHook();", { document: fnDocument });
assert.equal(objectFn.sandbox.via, 2);
assert.equal(fnPage.someHook(), 3);
const clickFn = run('https://example.com/', { isolated: true }, "let seen = 0; unsafeWindow.document.querySelector('p').addEventListener('click', function () { seen += 1; return seen; }); globalThis.seen = unsafeWindow.document.querySelector('p').listeners.click();", { document: fnDocument });
assert.equal(clickFn.sandbox.seen, 1);
assert.equal(fnNode.listeners.click(), 2);
const pageWindow = {
  webkit: { messageHandlers: { test: { postMessage() { return Promise.resolve(true); } } } },
  document: { title: 'old', querySelector() { return { id: 'p9', getAttribute(name) { return name === 'id' ? this.id : null; } }; } }
};
const direct = run('https://example.com/', { isolated: false, grants: ['none'] }, "globalThis.same = unsafeWindow === window; unsafeWindow.document.title = 'direct'; globalThis.title = unsafeWindow.document.title; globalThis.attr = unsafeWindow.document.querySelector('p').getAttribute('id');", { window: pageWindow });
assert.equal(direct.sandbox.same, true);
assert.equal(pageWindow.document.title, 'direct');
assert.equal(direct.sandbox.title, 'direct');
assert.equal(direct.sandbox.attr, 'p9');
const body = run('https://example.com/a', { runAt: 'document-body' });
assert.equal(body.sandbox.didRun, true);
const plain = run('https://example.com/', { grants: ['GM_xmlhttpRequest'] }, "GM_xmlhttpRequest({url:'https://example.com/a', method:'POST', data:'hello'});");
assert.equal(plain.calls[0].args.data, 'hello');
assert.equal(plain.calls[0].args.dataBase64, undefined);
const query = run('https://example.com/', { grants: ['GM_xmlhttpRequest'] }, "GM_xmlhttpRequest({url:'https://example.com/a', method:'POST', data: new URLSearchParams({q:'a b'})});");
assert.equal(query.calls[0].args.data, 'q=a+b');
assert.match(query.calls[0].args.headers['Content-Type'], /application\/x-www-form-urlencoded/);
(async () => {
  const form = run('https://example.com/', { grants: ['GM_xmlhttpRequest'] }, "const body = new FormData(); body.append('name', 'ada'); body.append('file', new Blob(['hi'], { type: 'text/plain' }), 'note.txt'); GM_xmlhttpRequest({url:'https://example.com/a', method:'POST', data: body});");
  await new Promise(resolve => setImmediate(resolve));
  const posted = form.calls.find(call => call.operation === 'xmlHttpRequest');
  const text = Buffer.from(posted.args.dataBase64, 'base64').toString('utf8');
  assert.match(text, /name="name"/);
  assert.match(text, /\r\nada\r\n/);
  assert.match(text, /filename="note.txt"/);
  assert.match(text, /Content-Type: text\/plain/);
  assert.match(text, /\r\nhi\r\n/);
  assert.match(posted.args.headers['Content-Type'], /^multipart\/form-data; boundary=/);
  assert.equal(posted.args.contentType, posted.args.headers['Content-Type']);
  const custom = run('https://example.com/', { grants: ['GM_xmlhttpRequest'] }, "const body = new FormData(); body.append('name', 'ada'); GM_xmlhttpRequest({url:'https://example.com/a', method:'POST', headers:{'Content-Type':'text/plain'}, data: body});");
  await new Promise(resolve => setImmediate(resolve));
  const kept = custom.calls.find(call => call.operation === 'xmlHttpRequest');
  assert.equal(kept.args.headers['Content-Type'], 'text/plain');
  assert.equal(kept.args.contentType, undefined);
  const streamed = run('https://example.com/', { grants: ['GM_xmlhttpRequest'], manualXHR: true }, "globalThis.states = []; globalThis.texts = []; globalThis.progress = []; GM_xmlhttpRequest({url:'https://example.com/a', responseType:'stream', onreadystatechange(res){ globalThis.states.push(res.readyState); globalThis.texts.push(res.responseText); }, onprogress(res){ globalThis.progress.push(res.loaded); }});");
  const streamID = streamed.calls.find(call => call.operation === 'xmlHttpRequest').args.id;
  streamed.sandbox.__rikuganXHREvent({ id: streamID, readyState: 1, responseText: '', loaded: 0, total: 0 });
  streamed.sandbox.__rikuganXHREvent({ id: streamID, readyState: 2, status: 200, statusText: 'OK', responseHeaders: 'Content-Type: text/plain', responseText: '', loaded: 0, total: 4, finalUrl: 'https://example.com/a' });
  streamed.sandbox.__rikuganXHREvent({ id: streamID, readyState: 3, status: 200, responseText: 'ab', chunkBase64: Buffer.from('ab').toString('base64'), loaded: 2, total: 4 });
  streamed.sandbox.__rikuganXHREvent({ id: streamID, readyState: 3, status: 200, responseText: 'abcd', chunkBase64: Buffer.from('cd').toString('base64'), loaded: 4, total: 4 });
  assert.equal(JSON.stringify(streamed.sandbox.states), JSON.stringify([1, 2, 3, 3]));
  assert.equal(JSON.stringify(streamed.sandbox.texts), JSON.stringify(['', '', 'ab', 'abcd']));
  assert.equal(JSON.stringify(streamed.sandbox.progress), JSON.stringify([2, 4]));
  streamed.resolvers[0]({ readyState: 4, status: 200, statusText: 'OK', responseText: 'abcd', responseHeaders: 'Content-Type: text/plain', finalUrl: 'https://example.com/a', responseBase64: Buffer.from('abcd').toString('base64') });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(streamed.sandbox.states.at(-1), 4);
  assert.equal(streamed.sandbox.texts.at(-1), 'abcd');
  assert.equal(streamed.sandbox.progress.length, 2);
  const closing = run('https://example.com/', { grants: ['none'] }, 'window.close();');
  assert.equal(closing.calls.some(call => call.operation === 'closeTab'), true);
  const denied = run('https://example.com/', {}, 'globalThis.note = typeof GM_notification; globalThis.closer = typeof window.close;');
  assert.equal(denied.sandbox.note, 'undefined');
  assert.equal(denied.sandbox.closer, 'function');
  const note = run('https://example.com/', { grants: ['GM_notification'] }, "globalThis.id = GM_notification({ title: 'Hi', text: 'Body', onclick() { globalThis.clicked = true; } });");
  const noticeCall = note.calls.find(call => call.operation === 'notification');
  assert.equal(noticeCall.args.title, 'Hi');
  assert.equal(noticeCall.args.text, 'Body');
  assert.equal(noticeCall.args.id, note.sandbox.id);
  note.sandbox.__rikuganNotify(note.sandbox.id);
  assert.equal(note.sandbox.clicked, true);
  const download = run('https://example.com/', { grants: ['GM_download'] }, "GM_download({ url: 'https://example.com/a.bin', name: 'a.bin' });");
  const saved = download.calls.find(call => call.operation === 'download');
  assert.equal(saved.args.url, 'https://example.com/a.bin');
  assert.equal(saved.args.name, 'a.bin');
  const cookies = run('https://example.com/', { grants: ['GM_cookie'] }, 'GM_cookie.list({}); GM_cookie.set({ name: "sid", value: "1" }); GM_cookie.delete({ name: "sid" });');
  assert.equal(JSON.stringify(cookies.calls.map(call => call.operation)), JSON.stringify(['cookieList', 'cookieSet', 'cookieDelete']));
  const tabs = run('https://example.com/', { grants: ['GM_getTab', 'GM_saveTab', 'GM_getTabs'] }, 'GM_getTab(); GM_saveTab({ n: 1 }); GM_getTabs();');
  assert.equal(JSON.stringify(tabs.calls.map(call => call.operation)), JSON.stringify(['getTab', 'saveTab', 'getTabs']));
  assert.equal(JSON.stringify(tabs.calls[1].args.data), JSON.stringify({ n: 1 }));
  const doc = {
    body: { kids: [], appendChild(el) { this.kids.push(el); } },
    createElement(tag) { return { tagName: tag, attrs: {}, textContent: '', setAttribute(name, value) { this.attrs[name] = value; } }; }
  };
  const added = run('https://example.com/', { grants: ['GM_addElement'], isolated: false }, "globalThis.el = GM_addElement('div', { id: 'n', textContent: 'hi' });", { document: doc });
  assert.equal(added.sandbox.el.tagName, 'div');
  assert.equal(added.sandbox.el.textContent, 'hi');
  assert.equal(added.sandbox.el.attrs.id, 'n');
  assert.equal(doc.body.kids.length, 1);
  const pageDocument = {
    body: { children: [], appendChild(el) { this.children.push(el); } },
    createElement(tag) {
      return { tagName: String(tag).toUpperCase(), id: '', textContent: '', attrs: {}, setAttribute(name, value) { this.attrs[name] = value; if (name === 'id') this.id = value; } };
    }
  };
  const hostNode = {
    attrs: {},
    scripts: [],
    appendChild(el) { this.scripts.push(el.textContent); vm.runInNewContext(el.textContent, { document: pageDocument, JSON }); },
    setAttribute(name, value) { this.attrs[name] = value; },
    getAttribute(name) { return Object.prototype.hasOwnProperty.call(this.attrs, name) ? this.attrs[name] : null; },
    removeAttribute(name) { delete this.attrs[name]; }
  };
  pageDocument.documentElement = hostNode;
  const isolatedElement = run('https://example.com/', { isolated: true, grants: ['GM_addElement'] }, "globalThis.made = GM_addElement('span', { id: 'n', textContent: 'hi' });", {
    document: { createElement() { return { textContent: '', remove() {} }; }, documentElement: hostNode }
  });
  assert.equal(isolatedElement.sandbox.made.id, 'n');
  assert.equal(isolatedElement.sandbox.made.tag, 'SPAN');
  assert.equal(isolatedElement.sandbox.made.text, 'hi');
  assert.equal(pageDocument.body.children.length, 1);
  assert.match(hostNode.scripts[0], /createElement/);
  const moved = run('https://example.com/a', {}, 'globalThis.runs = (globalThis.runs || 0) + 1; window.onurlchange = info => { globalThis.changes = (globalThis.changes || 0) + 1; globalThis.seen = info.url; globalThis.oldURL = info.oldURL; };');
  assert.equal(moved.sandbox.changes, undefined);
  moved.sandbox.__rikuganOnURLChange();
  assert.equal(moved.sandbox.changes, 1);
  assert.equal(moved.sandbox.seen, 'https://example.com/a');
  assert.equal(moved.sandbox.runs, 1);
  moved.sandbox.location = new URL('https://example.com/b');
  moved.sandbox.__rikuganOnURLChange();
  assert.equal(moved.sandbox.changes, 2);
  assert.equal(moved.sandbox.seen, 'https://example.com/b');
  assert.equal(moved.sandbox.oldURL, 'https://example.com/a');
  assert.equal(moved.sandbox.runs, 2);
  moved.sandbox.__rikuganOnURLChange();
  assert.equal(moved.sandbox.changes, 2);
  assert.equal(moved.sandbox.runs, 2);
  const pageWindow = {
    pageValue: 1,
    pageObject: { n: 1 },
    pageFunction(value) { return value + 1; },
    listeners: {},
    addEventListener(type, fn) { this.listeners[type] = fn; },
    dispatchEvent(event) { const fn = this.listeners[event.type]; if (fn) fn(event); },
    webkit: { messageHandlers: { test: { postMessage() { return Promise.resolve(true); } } } }
  };
  const grantNone = run('https://example.com/', { grants: ['none'], isolated: false }, "globalThis.read = window.pageValue; window.pageObject.n = 2; globalThis.called = window.pageFunction(3); window.addEventListener('ping', event => { globalThis.event = event.detail; }); window.dispatchEvent({ type: 'ping', detail: 9 }); window.exposed = 7;", { window: pageWindow });
  assert.equal(grantNone.sandbox.read, 1);
  assert.equal(pageWindow.pageObject.n, 2);
  assert.equal(grantNone.sandbox.called, 4);
  assert.equal(grantNone.sandbox.event, 9);
  assert.equal(pageWindow.exposed, 7);
  const isolatedWindow = { pageValue: 'isolated', webkit: { messageHandlers: { test: { postMessage() { return Promise.resolve(true); } } } } };
  const granted = run('https://example.com/', { grants: ['GM_getValue'], isolated: true }, 'globalThis.seen = window.pageValue; globalThis.pageSeen = window.pageObject;', { window: isolatedWindow });
  assert.equal(granted.sandbox.seen, 'isolated');
  assert.equal(granted.sandbox.pageSeen, undefined);
  const child = { top: {}, webkit: { messageHandlers: { test: { postMessage() { return Promise.resolve(true); } } } } };
  const iframe = run('https://example.com/frame', { noFrames: false }, 'globalThis.frameRan = true;', { window: child });
  assert.equal(iframe.sandbox.frameRan, true);
  console.log('PASS: userscript runtime URL guards, grants, resources, unsafeWindow get/set/call, page-world window, menu, xhr and listeners');
})().catch(error => { console.error(error); process.exit(1); });

