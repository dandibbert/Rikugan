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
    world: 'MAIN',
    func: function () { return 1; },
    args: [2]
  });
  const scriptMessage = posted[posted.length - 1];
  assert.equal(scriptMessage.api, 'scripting.executeScript');
  assert.equal(scriptMessage.details.world, 'MAIN');
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
  const filePromise = popup.chrome.scripting.executeScript({ files: ['injected.js'], world: 'MAIN' });
  const fileMessage = posted[posted.length - 1];
  assert.equal(fileMessage.api, 'scripting.executeScript');
  assert.deepEqual(fileMessage.details.files, ['injected.js']);
  assert.equal(fileMessage.details.world, 'MAIN');
  popup.__rgExtPending[fileMessage.id]({ result: [{ result: 1 }] });
  assert.deepEqual(await filePromise, [{ result: 1 }]);
  const cssFilePromise = popup.chrome.scripting.insertCSS({ files: ['a.css'], world: 'ISOLATED' });
  const cssFile = posted[posted.length - 1];
  assert.equal(cssFile.api, 'scripting.insertCSS');
  assert.deepEqual(cssFile.details.files, ['a.css']);
  assert.equal(cssFile.details.world, 'ISOLATED');
  popup.__rgExtPending[cssFile.id]({ result: null });
  assert.equal(await cssFilePromise, null);

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
  const contentPromise = content.chrome.scripting.executeScript({ code: 'document.title', world: 'MAIN' });
  assert.equal(page[0].source, 'rikugan-extension-host');
  assert.equal(page[0].payload.api, 'scripting.executeScript');
  assert.equal(page[0].payload.details.code, 'document.title');
  assert.equal(page[0].payload.details.world, 'MAIN');
  listeners[listeners.length - 1]({ data: { source: 'rikugan-extension-host-result', id: page[0].payload.id, result: 'fixture' } });
  assert.equal(await contentPromise, 'fixture');
  const isolatedPromise = content.chrome.scripting.executeScript({ files: ['injected.js'] });
  const isolatedMessage = page[page.length - 1].payload;
  assert.equal(isolatedMessage.api, 'scripting.executeScript');
  assert.equal(isolatedMessage.details.world, 'ISOLATED');
  assert.deepEqual(isolatedMessage.details.files, ['injected.js']);
  listeners[listeners.length - 1]({ data: { source: 'rikugan-extension-host-result', id: isolatedMessage.id, result: { sources: ['2+2'] } } });
  assert.equal(JSON.stringify(await isolatedPromise), JSON.stringify([{ result: 4 }]));
  assert.equal(typeof contentRuntime, 'function');
  let responded = null;
  const relayed = contentRuntime({ source: 'rikugan-extension-host', payload: { id: 'from-worker', api: 'notifications.create', details: { id: 'rikugan-demo', options: { title: 'Rikugan', message: '通知已创建' } } } }, {}, value => { responded = value; });
  assert.equal(relayed, true);
  const relayedPage = page.find(item => item.payload && item.payload.id === 'from-worker');
  assert.equal(relayedPage.payload.id, 'from-worker');
  listeners[listeners.length - 1]({ data: { source: 'rikugan-extension-host-result', id: 'from-worker', result: 'rikugan-demo' } });
  assert.equal(JSON.stringify(responded), JSON.stringify({ result: 'rikugan-demo' }));

  const record = { id: 'rikugan-demo', title: 'Rikugan', message: '通知已创建', buttons: [] };
  const clicks = [];
  const buttonClicks = [];
  const noteWorker = load({
    chrome: {
      runtime: { id: 'ext-1' },
      tabs: {
        sendMessage(_tabId, message, callback) {
          const payload = message.payload;
          if (payload.api === 'notifications.update') {
            const options = payload.details.options || {};
            record.title = options.title;
            record.message = options.message;
            record.buttons = (options.buttons || []).map(button => button.title);
            if (options.progress != null) record.progress = Math.max(0, Math.min(100, Number(options.progress)));
            if (options.iconUrl != null) record.iconUrl = options.iconUrl;
            if (options.imageUrl != null) record.imageUrl = options.imageUrl;
            callback({ result: true });
            return;
          }
          if (payload.api === 'notifications.poll') {
            callback({ result: [
              { type: 'clicked', notificationId: record.id },
              { type: 'button', notificationId: record.id, buttonIndex: 0 },
              { type: 'closed', notificationId: record.id, byUser: true },
              { type: 'settings', notificationId: record.id },
              { type: 'shown', notificationId: record.id }
            ] });
            return;
          }
          callback({ result: null });
        },
        query(_query, callback) { callback([{ id: 4 }]); }
      }
    }
  });
  noteWorker.chrome.notifications.onClicked.addListener(id => clicks.push(id));
  noteWorker.chrome.notifications.onButtonClicked.addListener((id, index) => buttonClicks.push([id, index]));
  const updated = await noteWorker.chrome.notifications.update('rikugan-demo', { title: 'Updated', message: 'changed', buttons: [{ title: 'Open' }], progress: 80, iconUrl: 'icons/icon.png', imageUrl: 'https://example.com/a.png' });
  assert.equal(updated, true);
  assert.equal(record.title, 'Updated');
  assert.equal(record.message, 'changed');
  assert.deepEqual(record.buttons, ['Open']);
  assert.equal(record.progress, 80);
  assert.equal(record.iconUrl, 'icons/icon.png');
  assert.equal(record.imageUrl, 'https://example.com/a.png');
  const closed = [];
  const settings = [];
  noteWorker.chrome.notifications.onClosed.addListener((id, byUser) => closed.push([id, byUser]));
  noteWorker.chrome.notifications.onShowSettings.addListener(() => settings.push('settings'));
  const shown = [];
  noteWorker.chrome.notifications.onShown.addListener(id => shown.push(id));
  await noteWorker.__rikuganPollNotifications();
  assert.deepEqual(clicks, ['rikugan-demo']);
  assert.deepEqual(buttonClicks, [['rikugan-demo', 0]]);
  assert.deepEqual(closed, [['rikugan-demo', true]]);
  assert.deepEqual(settings, ['settings']);
  assert.deepEqual(shown, ['rikugan-demo']);

  const routed = [];
  const nativePosted = [];
  const routedBox = load({
    chrome: {
      runtime: { id: 'ext-1' },
      tabs: {
        sendMessage(tabId, message, callback) {
          routed.push({ tabId, api: message.payload.api, target: message.payload.details.target });
          if (message.payload.api === 'notifications.getPermissionLevel') callback({ result: 'granted' });
          else callback({ result: [{ result: 7 }] });
        },
        query(_query, callback) { callback([{ id: 4 }]); }
      }
    },
    webkit: { messageHandlers: { rikuganExtension: { postMessage(payload) { nativePosted.push(payload); } } } }
  });
  const routedResult = await routedBox.chrome.scripting.executeScript({ target: { tabId: 9, allFrames: true, frameIds: [0, 1] }, world: 'MAIN', code: '1' });
  assert.equal(routed[0].tabId, 9);
  assert.equal(routed[0].api, 'scripting.executeScript');
  assert.equal(routed[0].target.allFrames, true);
  assert.deepEqual(routed[0].target.frameIds, [0, 1]);
  assert.equal(nativePosted.length, 0);
  assert.equal(JSON.stringify(routedResult), JSON.stringify([{ result: 7 }]));
  const levelPromise = routedBox.chrome.notifications.getPermissionLevel();
  const levelPosted = nativePosted[nativePosted.length - 1];
  assert.equal(levelPosted.api, 'notifications.getPermissionLevel');
  routedBox.__rgExtPending[levelPosted.id]({ result: 'denied' });
  assert.equal(await levelPromise, 'denied');

  const frameListeners = [];
  const pageMessages = [];
  const frameWindow = {
    postMessage(data) { pageMessages.push(data); },
    addEventListener(_type, fn) { frameListeners.push(fn); },
    removeEventListener() {},
    top: null,
    frames: [{
      frames: [],
      postMessage(data) {
        frameListeners.forEach(fn => fn({ data: { source: 'rikugan-extension-frame-result', id: data.id, result: [{ result: 9 }] } }));
      }
    }]
  };
  frameWindow.top = frameWindow;
  const framed = load({
    window: frameWindow,
    location: { protocol: 'http:' },
    chrome: { runtime: { onMessage: { addListener() {} } } }
  });
  const again = framed.chrome.scripting.executeScript({ code: '2+2', target: { allFrames: true } });
  const asked = pageMessages[pageMessages.length - 1];
  assert.equal(asked.payload.details.target.allFrames, true);
  frameListeners[frameListeners.length - 1]({ data: { source: 'rikugan-extension-host-result', id: asked.payload.id, result: { sources: ['2+2'] } } });
  assert.equal(JSON.stringify(await again), JSON.stringify([{ result: 4 }, { result: 9 }]));

  console.log('PASS: extension bridge scripting and notifications payloads');
})().catch(error => { console.error(error); process.exit(1); });
