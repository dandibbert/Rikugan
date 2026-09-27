const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync('Rikugan/Resources/ExtensionBridge.js', 'utf8');

function load(extra) {
  const sandbox = { console, Function, Promise, JSON, setTimeout, clearTimeout, ...extra };
  sandbox.globalThis = sandbox;
  vm.runInNewContext(source, sandbox, { filename: 'ExtensionBridge.js' });
  return sandbox;
}

(async () => {
  const posted = [];
  const popup = load({
    posted,
    chrome: {},
    webkit: { messageHandlers: { rikuganExtension: { postMessage(payload) { posted.push(JSON.parse(JSON.stringify(payload))); } } } }
  });
  const cssPromise = popup.chrome.scripting.insertCSS({ css: 'body{color:red}', target: { tabId: 3 }, world: 'MAIN' });
  assert.equal(posted.length, 1);
  assert.equal(posted[0].api, 'scripting.insertCSS');
  assert.equal(posted[0].details.css, 'body{color:red}');
  assert.equal(posted[0].details.target.tabId, 3);
  assert.equal(posted[0].details.world, 'MAIN');
  popup.__rgExtPending[posted[0].id]({ result: null });
  assert.equal(await cssPromise, null);

  const scriptPromise = popup.chrome.scripting.executeScript({
    target: { tabId: 3 },
    func: function () { return 1; },
    args: [2]
  });
  const scriptMessage = posted[posted.length - 1];
  assert.equal(scriptMessage.api, 'scripting.executeScript');
  assert.match(scriptMessage.details.func, /function/);
  assert.deepEqual(scriptMessage.details.args, [2]);
  popup.__rgExtPending[scriptMessage.id]({ result: [{ result: 1 }] });
  assert.deepEqual(await scriptPromise, [{ result: 1 }]);

  const notePromise = popup.chrome.notifications.create('rikugan-demo', { title: 'Rikugan', message: '通知已创建' });
  const note = posted[posted.length - 1];
  assert.equal(note.api, 'notifications.create');
  assert.equal(note.details.id, 'rikugan-demo');
  assert.equal(note.details.options.title, 'Rikugan');
  assert.equal(note.details.options.message, '通知已创建');
  popup.__rgExtPending[note.id]({ result: 'rikugan-demo' });
  assert.equal(await notePromise, 'rikugan-demo');
  const before = posted.length;
  await assert.rejects(popup.chrome.scripting.executeScript({ files: ['a.js'], code: '1' }), /files are not forwarded/);
  assert.equal(posted.length, before);

  let nativeCalls = 0;
  function nativeInsert() { nativeCalls += 1; return Promise.resolve('native'); }
  const kept = load({
    chrome: { scripting: { insertCSS: nativeInsert, executeScript: nativeInsert } },
    webkit: { messageHandlers: { rikuganExtension: { postMessage() { throw new Error('should not post'); } } } }
  });
  assert.equal(await kept.chrome.scripting.insertCSS({ css: 'x' }), 'native');
  assert.equal(nativeCalls, 1);
  assert.equal(typeof kept.chrome.notifications.create, 'function');

  const sent = [];
  const worker = load({
    chrome: {
      runtime: {},
      tabs: {
        sendMessage(tabId, message, callback) {
          sent.push({ tabId, message });
          callback({ result: { 'rikugan-demo': { title: 'Rikugan', message: '通知已创建' } } });
        },
        query(_query, callback) { callback([{ id: 4 }]); }
      }
    }
  });
  worker.browser = worker.chrome;
  const listed = await worker.chrome.notifications.getAll();
  assert.equal(sent[0].tabId, 4);
  assert.equal(sent[0].message.source, 'rikugan-extension-host');
  assert.equal(sent[0].message.payload.api, 'notifications.getAll');
  assert.equal(listed['rikugan-demo'].message, '通知已创建');
  await worker.chrome.scripting.insertCSS({ target: { tabId: 9 }, css: 'body{color:red}' });
  assert.equal(sent[1].tabId, 9);
  assert.equal(sent[1].message.payload.api, 'scripting.insertCSS');
  assert.equal(sent[1].message.payload.details.css, 'body{color:red}');

  const page = [];
  const listeners = [];
  let contentRuntime = null;
  const contentWindow = {
    postMessage(data) { page.push(data); },
    addEventListener(_type, fn) { listeners.push(fn); },
    removeEventListener() {},
    top: null
  };
  contentWindow.top = contentWindow;
  const content = load({
    window: contentWindow,
    location: { protocol: 'http:' },
    chrome: { runtime: { onMessage: { addListener(fn) { contentRuntime = fn; } } } }
  });
  const contentPromise = content.chrome.scripting.executeScript({ code: 'document.title' });
  assert.equal(page[0].source, 'rikugan-extension-host');
  assert.equal(page[0].payload.api, 'scripting.executeScript');
  assert.equal(page[0].payload.details.code, 'document.title');
  listeners[0]({ data: { source: 'rikugan-extension-host-result', id: page[0].payload.id, result: 'fixture' } });
  assert.equal(await contentPromise, 'fixture');
  assert.equal(typeof contentRuntime, 'function');
  let responded = null;
  const relayed = contentRuntime({ source: 'rikugan-extension-host', payload: { id: 'from-worker', api: 'notifications.create', details: { id: 'rikugan-demo', options: { title: 'Rikugan', message: '通知已创建' } } } }, {}, value => { responded = value; });
  assert.equal(relayed, true);
  assert.equal(page[1].payload.id, 'from-worker');
  listeners[listeners.length - 1]({ data: { source: 'rikugan-extension-host-result', id: 'from-worker', result: 'rikugan-demo' } });
  assert.equal(JSON.stringify(responded), JSON.stringify({ result: 'rikugan-demo' }));

  console.log('PASS: extension bridge scripting and notifications payloads');
})().catch(error => { console.error(error); process.exit(1); });
