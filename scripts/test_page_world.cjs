const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const template = fs.readFileSync('Rikugan/Resources/UserscriptRuntime.js', 'utf8');
const html = fs.readFileSync('Tests/Fixtures/page-world.html', 'utf8');
const pageScript = (html.match(/<script>([\s\S]*?)<\/script>/) || [])[1];
assert.ok(pageScript, 'page-world.html has no script');
assert.match(html, /pageValue/);
assert.match(html, /pageFunction/);
assert.match(html, /addEventListener\('ping'/);
assert.match(html, /iframe/);

function scriptWorld(grants, injectInto) {
  if (injectInto === 'page') return false;
  return Array.isArray(grants) && grants.length > 0 && !grants.includes('none');
}

function loadFixture(search, parent) {
  const location = new URL('https://example.com/world' + (search || ''));
  const status = { textContent: 'waiting' };
  const document = { getElementById(id) { return id === 'status' ? status : null; } };
  const page = {
    location,
    document,
    listeners: {},
    addEventListener(type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); },
    dispatchEvent(event) { (this.listeners[event.type] || []).forEach(fn => fn(event)); },
    top: null,
    webkit: { messageHandlers: { test: { postMessage() { return Promise.resolve(true); } } } }
  };
  page.top = parent || page;
  vm.runInNewContext(pageScript, { window: page, document, location, URLSearchParams }, { filename: 'page-world.html' });
  page.status = status;
  return page;
}

function run(url, override, source, page, document) {
  const config = {
    id: 'test', name: 'Test', version: '1', handler: 'test',
    matches: ['https://*.example.com/*'], includes: [], excludes: [], excludeMatches: [],
    grants: [], runAt: 'document-end', storage: {}, isolated: false, ...override
  };
  const sandbox = {
    location: new URL(url),
    URL, URLSearchParams, console, setTimeout, JSON,
    window: page,
    document: document || page.document
  };
  const script = template.replace('/*__CONFIG__*/', JSON.stringify(config)).replace('/*__SOURCE__*/', source);
  vm.runInNewContext(script, sandbox, { filename: 'UserscriptRuntime.js' });
  return sandbox;
}

const checks = `
globalThis.read = window.pageValue;
window.pageObject.n = (window.pageObject.n || 0) + 1;
globalThis.called = window.pageFunction(3);
globalThis.same = unsafeWindow === window;
globalThis.viaUnsafe = unsafeWindow.pageValue;
globalThis.unsafeCalled = unsafeWindow.pageFunction(4);
window.addEventListener('ping', event => { globalThis.event = event.detail; });
window.dispatchEvent({ type: 'ping', detail: window.pageValue });
window.exposed = 'page';
`;

function assertPageChecks(page, sandbox, expected) {
  assert.equal(sandbox.read, expected);
  assert.equal(sandbox.called, 4);
  assert.equal(sandbox.same, true);
  assert.equal(sandbox.viaUnsafe, expected);
  assert.equal(sandbox.unsafeCalled, 5);
  assert.equal(sandbox.event, expected);
  assert.equal(page.exposed, 'page');
  assert.equal(page.pageObject.n, 2);
  assert.equal(page.status.textContent, 'event ' + expected);
}

const grantPage = loadFixture('');
assert.equal(scriptWorld(['none'], undefined), false);
const grantNone = run('https://example.com/world', { grants: ['none'], isolated: scriptWorld(['none']) }, checks, grantPage);
assertPageChecks(grantPage, grantNone, 1);

const injectPage = loadFixture('');
assert.equal(scriptWorld(['GM_getValue'], 'page'), false);
const injected = run('https://example.com/world', { grants: ['GM_getValue'], isolated: scriptWorld(['GM_getValue'], 'page'), injectInto: 'page' }, checks, injectPage);
assertPageChecks(injectPage, injected, 1);

const isolatedPage = loadFixture('');
const isolatedWindow = {
  listeners: {},
  addEventListener(type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); },
  dispatchEvent(event) { (this.listeners[event.type] || []).forEach(fn => fn(event)); },
  top: null,
  webkit: { messageHandlers: { test: { postMessage() { return Promise.resolve(true); } } } }
};
isolatedWindow.top = isolatedWindow;
assert.equal(scriptWorld(['GM_getValue'], undefined), true);
const isolated = run('https://example.com/world', { grants: ['GM_getValue'], isolated: true }, `
globalThis.seen = window.pageValue;
globalThis.pageSeen = window.pageObject;
window.marker = 'iso';
window.pageValue = 'leaked';
`, isolatedWindow);
assert.equal(isolated.seen, undefined);
assert.equal(isolated.pageSeen, undefined);
assert.equal(isolatedWindow.marker, 'iso');
assert.equal(isolatedPage.pageValue, 1);
assert.equal(isolatedPage.marker, undefined);
assert.equal(isolatedPage.exposed, undefined);

const bridgePage = loadFixture('');
const documentElement = {
  attrs: {},
  appendChild(el) { vm.runInNewContext(el.textContent, { window: bridgePage, document: { documentElement, getElementById: bridgePage.document.getElementById }, JSON, location: bridgePage.location }); },
  setAttribute(name, value) { this.attrs[name] = value; },
  getAttribute(name) { return Object.prototype.hasOwnProperty.call(this.attrs, name) ? this.attrs[name] : null; },
  removeAttribute(name) { delete this.attrs[name]; }
};
const bridgeDocument = { createElement() { return { textContent: '', remove() {} }; }, documentElement };
const isolatedForBridge = {
  listeners: {},
  addEventListener() {},
  dispatchEvent() {},
  top: null,
  webkit: { messageHandlers: { test: { postMessage() { return Promise.resolve(true); } } } }
};
isolatedForBridge.top = isolatedForBridge;
const bridgedAgain = run('https://example.com/world?bridge=1', { grants: ['unsafeWindow'], isolated: true }, `
globalThis.read = unsafeWindow.pageValue;
unsafeWindow.touched = 5;
globalThis.called = unsafeWindow.pageFunction(8);
`, isolatedForBridge, bridgeDocument);
assert.equal(bridgedAgain.read, 1);
assert.equal(bridgePage.touched, 5);
assert.equal(bridgedAgain.called, 9);
assert.equal(bridgePage.pageValue, 1);

function replay(page, url) {
  return run(url, { grants: ['none'], isolated: false }, `
globalThis.reads = (globalThis.reads || []).concat(window.pageValue);
globalThis.calls = (globalThis.calls || []).concat(window.pageFunction(1));
window.addEventListener('ping', event => { globalThis.events = (globalThis.events || []).concat(event.detail); });
window.dispatchEvent({ type: 'ping', detail: window.pageValue });
`, page);
}

const reloaded = loadFixture('');
const first = replay(reloaded, 'https://example.com/world');
assert.equal(JSON.stringify(first.reads), JSON.stringify([1]));
assert.equal(JSON.stringify(first.calls), JSON.stringify([2]));
assert.equal(JSON.stringify(first.events), JSON.stringify([1]));
reloaded.pageValue = 99;
vm.runInNewContext(pageScript, { window: reloaded, document: reloaded.document, location: reloaded.location, URLSearchParams }, { filename: 'page-world.html' });
assert.equal(reloaded.pageValue, 1);
const afterReload = replay(reloaded, 'https://example.com/world?reload=1');
assert.equal(JSON.stringify(afterReload.reads), JSON.stringify([1]));
assert.equal(JSON.stringify(afterReload.calls), JSON.stringify([2]));
assert.equal(reloaded.status.textContent, 'event 1');

const spaPage = loadFixture('');
const spa = replay(spaPage, 'https://example.com/world');
assert.equal(JSON.stringify(spa.reads), JSON.stringify([1]));
spa.location = new URL('https://example.com/world/next');
spa.__rikuganOnURLChange();
assert.equal(JSON.stringify(spa.reads), JSON.stringify([1, 1]));
assert.equal(JSON.stringify(spa.calls), JSON.stringify([2, 2]));
assert.equal(spaPage.pageValue, 1);

const top = loadFixture('');
const frame = loadFixture('?frame=1', top);
assert.notEqual(frame.top, frame);
assert.equal(frame.pageValue, 1);
const framed = replay(frame, 'https://example.com/world?frame=1');
assert.equal(JSON.stringify(framed.reads), JSON.stringify([1]));
assert.equal(framed.calls[0], 2);
assert.equal(top.exposed, undefined);

const popup = loadFixture('?popup=1');
assert.equal(popup.pageValue, 'popup');
const popupRun = replay(popup, 'https://example.com/world?popup=1');
assert.equal(JSON.stringify(popupRun.reads), JSON.stringify(['popup']));
assert.equal(popupRun.calls[0], 2);
const opened = loadFixture('?tab=newtab');
assert.equal(opened.pageValue, 'newtab');
const tabRun = replay(opened, 'https://example.com/world?tab=newtab');
assert.equal(JSON.stringify(tabRun.reads), JSON.stringify(['newtab']));

console.log('PASS: page-world fixture grant none, isolated, unsafeWindow, inject-into page, reload, pushState, iframe, popup');
