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

  const gateHost = load({ chrome: { runtime: {} } });
  assert.equal(typeof gateHost.__rikuganCreateBackgroundGate, 'function');

  let releaseProbe;
  const probe = new Promise(resolve => { releaseProbe = resolve; });
  const heard = [];
  function backgroundListener(message) {
    heard.push(message);
    return { from: 'listener', n: message.n };
  }
  function originalSend(message) {
    if (message && message.source === 'rikugan-bg-probe') return probe;
    return Promise.resolve(backgroundListener(message));
  }
  const portLog = [];
  function originalConnect(info) {
    return {
      name: info.name,
      postMessage(message) { portLog.push({ name: info.name, n: message.n, from: message.from }); }
    };
  }
  const coldWindow = { addEventListener() {}, removeEventListener() {}, postMessage() {}, top: null };
  coldWindow.top = coldWindow;
  const coldHost = load({
    window: coldWindow,
    location: { protocol: 'http:' },
    chrome: { runtime: { sendMessage: originalSend, connect: originalConnect, onMessage: { addListener() {} } } }
  });
  assert.equal(coldHost.__rikuganBackgroundGate.state, 'starting');
  const first = coldHost.chrome.runtime.sendMessage({ n: 1, from: 'content' });
  const popupMessage = coldHost.chrome.runtime.sendMessage({ n: 2, from: 'popup' });
  const earlyPort = coldHost.chrome.runtime.connect({ name: 'early', tabId: 3 });
  earlyPort.postMessage({ n: 1, from: 'content' });
  earlyPort.postMessage({ n: 2, from: 'popup' });
  assert.equal(heard.length, 0);
  assert.equal(portLog.length, 0);
  assert.equal(earlyPort.pending, true);
  assert.equal(coldHost.__rikuganBackgroundGate.pendingCount(), 2);
  releaseProbe({ ready: true });
  assert.equal((await first).from, 'listener');
  assert.equal((await first).n, 1);
  assert.equal((await popupMessage).n, 2);
  assert.deepEqual(heard.map(message => message.n), [1, 2]);
  assert.deepEqual(heard.map(message => message.from), ['content', 'popup']);
  assert.deepEqual(portLog, [{ name: 'early', n: 1, from: 'content' }, { name: 'early', n: 2, from: 'popup' }]);
  earlyPort.postMessage({ n: 3, from: 'after' });
  assert.equal(portLog[portLog.length - 1].n, 3);
  assert.equal(earlyPort.pending, false);
  assert.equal(coldHost.__rikuganBackgroundGate.state, 'ready');

  let emptyProbes = 0;
  const retryWindow = { addEventListener() {}, removeEventListener() {}, postMessage() {}, top: null };
  retryWindow.top = retryWindow;
  const retryHost = load({
    window: retryWindow,
    location: { protocol: 'http:' },
    chrome: {
      runtime: {
        sendMessage(message) {
          if (message && message.source === 'rikugan-bg-probe') {
            emptyProbes += 1;
            if (emptyProbes === 1) return Promise.resolve(undefined);
            return Promise.resolve({ ready: true });
          }
          return Promise.resolve({ ok: true, visits: message.type === 'rikugan-probe' ? 8 : 0 });
        },
        onMessage: { addListener() {} }
      }
    }
  });
  assert.equal(retryHost.__rikuganBackgroundGate.state, 'starting');
  const queuedDuringProbe = retryHost.chrome.runtime.sendMessage({ type: 'rikugan-probe' });
  const queuedReply = await queuedDuringProbe;
  assert.ok(emptyProbes >= 2);
  assert.equal(queuedReply.ok, true);
  assert.equal(queuedReply.visits, 8);
  assert.equal(retryHost.__rikuganBackgroundGate.state, 'ready');

  let callbackAnswers = 0;
  let userMessagesBeforeReady = 0;
  const callbackWindow = { addEventListener() {}, removeEventListener() {}, postMessage() {}, top: null };
  callbackWindow.top = callbackWindow;
  const callbackProbeHost = load({
    window: callbackWindow,
    location: { protocol: 'http:' },
    chrome: {
      runtime: {
        sendMessage(message, callback) {
          if (message && message.source === 'rikugan-bg-probe') {
            if (typeof callback !== 'function') return undefined;
            callbackAnswers += 1;
            callback(callbackAnswers === 1 ? undefined : { ready: true });
            return undefined;
          }
          if (callbackAnswers < 2) userMessagesBeforeReady += 1;
          return Promise.resolve({ ok: true, visits: 9 });
        },
        onMessage: { addListener() {} }
      }
    }
  });
  assert.equal(callbackProbeHost.__rikuganBackgroundGate.state, 'starting');
  const callbackQueued = await callbackProbeHost.chrome.runtime.sendMessage({ type: 'rikugan-probe' });
  assert.ok(callbackAnswers >= 2);
  assert.equal(userMessagesBeforeReady, 0);
  assert.equal(callbackQueued.ok, true);
  assert.equal(callbackQueued.visits, 9);
  assert.equal(callbackProbeHost.__rikuganBackgroundGate.state, 'ready');

  const failedWindow = { addEventListener() {}, removeEventListener() {}, postMessage() {}, top: null };
  failedWindow.top = failedWindow;
  const failedHost = load({
    window: failedWindow,
    location: { protocol: 'http:' },
    chrome: {
      runtime: {
        sendMessage(message) {
          if (message && message.source === 'rikugan-bg-probe') return Promise.reject(new Error('worker missing'));
          return Promise.resolve({ unexpected: true });
        },
        onMessage: { addListener() {} }
      }
    }
  });
  const rejected = failedHost.chrome.runtime.sendMessage({ n: 9 });
  const rejectedPort = failedHost.chrome.runtime.connect({ name: 'queued' });
  await assert.rejects(rejected, /background failed/);
  assert.equal(failedHost.__rikuganBackgroundGate.state, 'failed');
  assert.equal(rejectedPort.disconnected, true);
  await assert.rejects(failedHost.chrome.runtime.sendMessage({ n: 10 }), /background failed/);
  assert.throws(() => failedHost.chrome.runtime.connect({ name: 'later' }), /background failed/);

  const callbackHost = load({
    chrome: {
      runtime: {
        sendMessage(message, callback) {
          if (typeof callback === 'function') setTimeout(() => callback({ ok: true, visits: message.type === 'rikugan-probe' ? 2 : 0 }), 0);
          return undefined;
        },
        onMessage: { addListener() {} }
      }
    }
  });
  const callbackReply = await callbackHost.chrome.runtime.sendMessage({ type: 'rikugan-probe' });
  assert.equal(callbackReply.ok, true);
  assert.equal(callbackReply.visits, 2);

  const lateHost = load({
    chrome: {
      runtime: {
        sendMessage(message, callback) {
          if (typeof callback === 'function') {
            callback(undefined);
            return undefined;
          }
          return new Promise(resolve => setTimeout(() => resolve({ ok: true, visits: 3 }), 20));
        },
        onMessage: { addListener() {} }
      }
    }
  });
  const lateReply = await lateHost.chrome.runtime.sendMessage({ type: 'rikugan-probe' });
  assert.equal(lateReply.ok, true);
  assert.equal(lateReply.visits, 3);

  const promiseHost = load({
    chrome: {
      runtime: {
        sendMessage(message, callback) {
          if (typeof callback === 'function') return {};
          return Promise.resolve({ ok: true, visits: message.type === 'rikugan-probe' ? 4 : 0 });
        },
        onMessage: { addListener() {} }
      }
    }
  });
  const promiseReply = await promiseHost.chrome.runtime.sendMessage({ type: 'rikugan-probe' });
  assert.equal(promiseReply.ok, true);
  assert.equal(promiseReply.visits, 4);

  const emptyCallbackHost = load({
    chrome: {
      runtime: {
        sendMessage(message, callback) {
          if (typeof callback === 'function') callback(undefined);
          return Promise.resolve({ ok: true, visits: message.type === 'rikugan-probe' ? 5 : 0 });
        },
        onMessage: { addListener() {} }
      }
    }
  });
  const emptyCallbackReply = await emptyCallbackHost.chrome.runtime.sendMessage({ type: 'rikugan-probe' });
  assert.equal(emptyCallbackReply.ok, true);
  assert.equal(emptyCallbackReply.visits, 5);

  let webkitProbeCalls = 0;
  const webkitHost = load({
    chrome: {
      runtime: {
        sendMessage(message, callback) {
          if (!message || message.type !== 'rikugan-probe') return Promise.resolve({ ready: true });
          webkitProbeCalls += 1;
          if (typeof callback === 'function') {
            callback(undefined);
            return undefined;
          }
          return Promise.resolve({ ok: true, visits: 6 });
        },
        onMessage: { addListener() {} }
      }
    }
  });
  const webkitReply = await webkitHost.chrome.runtime.sendMessage({ type: 'rikugan-probe' });
  assert.equal(webkitProbeCalls, 1);
  assert.equal(webkitReply.ok, true);
  assert.equal(webkitReply.visits, 6);

  const stressHeard = [];
  const gate = gateHost.__rikuganCreateBackgroundGate();
  const connected = [];
  const portHeard = [];
  gate.onConnect(port => {
    connected.push(port.name);
    port.onMessage.addListener(message => portHeard.push(message));
  });
  gate.setTransport({
    sendMessage(message) {
      stressHeard.push(message);
      return { from: 'listener', n: message.n, step: message.step };
    }
  });
  for (let round = 0; round < 24; round += 1) {
    gate.coldStart();
    assert.equal(gate.state, 'starting');
    const cold = gate.enqueueMessage({ n: round, step: 'cold' });
    const early = gate.connect({ name: 'early-' + round, tabId: round });
    early.postMessage({ n: round, step: 'port' });
    early.postMessage({ n: round, step: 'port-2' });
    assert.equal(early.pending, true);
    assert.equal(portHeard.filter(message => message.n === round).length, 0);
    gate.wake();
    assert.equal(gate.state, 'waking');
    assert.equal(gate.pendingCount(), 1);
    gate.markReady();
    assert.equal(gate.state, 'ready');
    assert.equal((await cold).from, 'listener');
    assert.equal((await cold).step, 'cold');
    assert.equal(early.pending, false);
    assert.deepEqual(portHeard.filter(message => message.n === round).map(message => message.step), ['port', 'port-2']);
    const live = gate.enqueueMessage({ n: round, step: 'live' });
    assert.equal((await live).step, 'live');
    const livePort = gate.connect({ name: 'live-' + round, tabId: round });
    assert.equal(livePort.pending, false);
    livePort.postMessage({ n: round, step: 'port-live' });
    assert.equal(portHeard.filter(message => message.n === round && message.step === 'port-live').length, 1);
    livePort.disconnect();
    assert.equal(livePort.disconnected, true);
    await gate.storageSet('round', round);
    assert.equal(await gate.storageGet('round'), round);
    gate.idle();
    assert.equal(gate.state, 'idle');
    const idle = gate.enqueueMessage({ n: round, step: 'idle' });
    assert.equal((await idle).step, 'idle');
    gate.suspend();
    gate.wake();
    assert.equal(gate.state, 'waking');
    const again = gate.enqueueMessage({ n: round, step: 'wake2' });
    gate.markReady();
    assert.equal((await again).step, 'wake2');
    gate.closeTab(round);
    assert.equal(early.disconnected, true);
    gate.shutdown();
    assert.equal(gate.state, 'shutdown');
    await assert.rejects(gate.enqueueMessage({ n: round, step: 'after' }), /background shutdown/);
    assert.throws(() => gate.connect({ name: 'closed' }), /background shutdown/);
    await assert.rejects(gate.storageSet('round', -1), /background shutdown/);
    gate.start();
    assert.equal(gate.state, 'shutdown');
    await assert.rejects(gate.enqueueMessage({ n: round, step: 'still' }), /background shutdown/);
    assert.equal(stressHeard.filter(message => message.n === round).map(message => message.step).join(','), 'cold,live,idle,wake2');
    assert.ok(connected.includes('early-' + round));
  }
  assert.equal(stressHeard.length, 24 * 4);

  const unsupportedHost = load({ chrome: { runtime: {} } });
  await assert.rejects(
    unsupportedHost.chrome.scripting.registerContentScripts([{ id: 'a', js: ['a.js'], matches: ['<all_urls>'] }]),
    /Unsupported: scripting.registerContentScripts/
  );
  await assert.rejects(
    unsupportedHost.chrome.scripting.unregisterContentScripts(['a']),
    /Unsupported: scripting.unregisterContentScripts/
  );
  await assert.rejects(
    unsupportedHost.chrome.scripting.getRegisteredContentScripts(),
    /Unsupported: scripting.getRegisteredContentScripts/
  );
  await assert.rejects(
    unsupportedHost.chrome.webRequest.onBeforeRequest.addListener(function () {}),
    /Unsupported: webRequest.onBeforeRequest/
  );
  assert.equal(unsupportedHost.chrome.runtime.lastError.message, 'Unsupported: webRequest.onBeforeRequest');
  assert.equal(unsupportedHost.chrome.webRequest.onBeforeRequest.hasListener(), false);
  let keptWebKit = false;
  const webkitScripting = load({
    chrome: {
      runtime: {},
      scripting: {
        registerContentScripts() { keptWebKit = true; return Promise.resolve('webkit'); }
      }
    }
  });
  assert.equal(await webkitScripting.chrome.scripting.registerContentScripts([]), 'webkit');
  assert.equal(keptWebKit, true);

  await assert.rejects(
    unsupportedHost.chrome.debugger.attach({ tabId: 1 }, '1.3'),
    /Unsupported: debugger.attach/
  );
  await assert.rejects(
    unsupportedHost.chrome.debugger.detach({ tabId: 1 }),
    /Unsupported: debugger.detach/
  );
  await assert.rejects(
    unsupportedHost.chrome.debugger.sendCommand({ tabId: 1 }, 'Page.reload'),
    /Unsupported: debugger.sendCommand/
  );
  await assert.rejects(unsupportedHost.chrome.debugger.getTargets(), /Unsupported: debugger.getTargets/);
  await assert.rejects(
    unsupportedHost.chrome.debugger.onEvent.addListener(function () {}),
    /Unsupported: debugger.onEvent/
  );
  await assert.rejects(
    unsupportedHost.chrome.runtime.sendNativeMessage('com.example.host', { ping: 1 }),
    /Unsupported: runtime.sendNativeMessage/
  );
  await assert.rejects(
    unsupportedHost.chrome.runtime.connectNative('com.example.host'),
    /Unsupported: runtime.connectNative/
  );
  await assert.rejects(
    unsupportedHost.chrome.runtime.onConnectNative.addListener(function () {}),
    /Unsupported: runtime.onConnectNative/
  );
  await assert.rejects(
    unsupportedHost.chrome.webRequest.onSendHeaders.addListener(function () {}),
    /Unsupported: webRequest.onSendHeaders/
  );
  await assert.rejects(
    unsupportedHost.chrome.webRequest.onBeforeRedirect.addListener(function () {}),
    /Unsupported: webRequest.onBeforeRedirect/
  );
  await assert.rejects(
    unsupportedHost.chrome.downloads.download({ url: 'https://example.com/file.bin' }),
    /Unsupported: downloads.download/
  );
  await assert.rejects(unsupportedHost.chrome.downloads.search({}), /Unsupported: downloads.search/);
  await assert.rejects(unsupportedHost.chrome.downloads.pause(1), /Unsupported: downloads.pause/);
  await assert.rejects(unsupportedHost.chrome.downloads.cancel(1), /Unsupported: downloads.cancel/);
  await assert.rejects(
    unsupportedHost.chrome.downloads.onCreated.addListener(function () {}),
    /Unsupported: downloads.onCreated/
  );
  await assert.rejects(
    unsupportedHost.chrome.webRequest.handlerBehaviorChanged(),
    /Unsupported: webRequest.handlerBehaviorChanged/
  );
  await assert.rejects(
    unsupportedHost.chrome.declarativeNetRequest.updateDynamicRules({
      addRules: [{ id: 1, action: { type: 'redirect', redirect: { url: 'https://example.com/' } }, condition: { urlFilter: 'a' } }]
    }),
    /Unsupported: declarativeNetRequest.redirect/
  );
  await assert.rejects(
    unsupportedHost.chrome.declarativeNetRequest.updateSessionRules({
      addRules: [{ id: 2, action: { type: 'modifyHeaders', responseHeaders: [] }, condition: { urlFilter: 'b' } }]
    }),
    /Unsupported: declarativeNetRequest.modifyHeaders/
  );
  await assert.rejects(
    unsupportedHost.chrome.declarativeNetRequest.updateDynamicRules({
      addRules: [{ id: 5, action: { type: 'block' }, condition: { urlFilter: 'e' } }]
    }),
    /Unsupported: declarativeNetRequest.updateDynamicRules/
  );
  let blockCalls = 0;
  const dnrHost = load({
    chrome: {
      runtime: {},
      declarativeNetRequest: {
        updateDynamicRules(options) {
          blockCalls += 1;
          return Promise.resolve(options.addRules[0].action.type);
        }
      }
    }
  });
  assert.equal(await dnrHost.chrome.declarativeNetRequest.updateDynamicRules({
    addRules: [{ id: 3, action: { type: 'block' }, condition: { urlFilter: 'c' } }]
  }), 'block');
  assert.equal(blockCalls, 1);
  await assert.rejects(
    dnrHost.chrome.declarativeNetRequest.updateDynamicRules({
      addRules: [{ id: 4, action: { type: 'redirect' }, condition: { urlFilter: 'd' } }]
    }),
    /Unsupported: declarativeNetRequest.redirect/
  );
  assert.equal(blockCalls, 1);

  const backgroundSource = fs.readFileSync('Examples/WebExtension/background.js', 'utf8');
  const backgroundListeners = [];
  function webkitSend(message) {
    let replied = false;
    let replyValue;
    function sendResponse(value) {
      replied = true;
      replyValue = value;
    }
    let handled = false;
    backgroundListeners.forEach(listener => {
      const returned = listener(message, { tab: { id: 4 } }, sendResponse);
      if (returned === true) handled = true;
    });
    return Promise.resolve(handled && replied ? replyValue : undefined);
  }
  const browser = {
    runtime: { onMessage: { addListener(fn) { backgroundListeners.push(fn); } }, sendMessage: webkitSend },
    storage: { local: { get() { return Promise.resolve({}); }, set() { return Promise.resolve(); } } },
    scripting: { insertCSS() { return Promise.resolve(); }, executeScript() { return Promise.resolve([]); } },
    notifications: { create() { return Promise.resolve('rikugan-demo'); }, getAll() { return Promise.resolve({ 'rikugan-demo': { title: 'Rikugan' } }); } },
    tabs: { query() { return Promise.resolve([{ id: 4 }]); } }
  };
  const backgroundSandbox = { browser, chrome: browser, console, Promise, setTimeout, clearTimeout };
  backgroundSandbox.globalThis = backgroundSandbox;
  vm.runInNewContext(backgroundSource, backgroundSandbox, { filename: 'background.js' });
  const ready = await webkitSend({ source: 'rikugan-bg-probe' });
  assert.equal(ready && ready.ready, true);
  const demoReply = await webkitSend({ type: 'rikugan-probe' });
  assert.equal(demoReply.ok, true);
  assert.equal(demoReply.visits, 1);
  const ignored = await webkitSend({ type: 'other' });
  assert.equal(ignored, undefined);

  // WebKit's extension namespace is readonly. Assigning a missing Main-world API
  // such as webRequest throws in the service worker and used to abort background.js
  // before onMessage.addListener. Content scripts still ran and painted 扩展后台异常.
  const readonlyListeners = [];
  const readonlyRuntime = {
    id: 'demo',
    sendMessage() { return Promise.resolve(undefined); },
    onMessage: { addListener(fn) { readonlyListeners.push(fn); } },
    connect() { return {}; }
  };
  const readonlyHost = {
    runtime: readonlyRuntime,
    storage: { local: { get() { return Promise.resolve({}); }, set() { return Promise.resolve(); } } },
    tabs: { query() { return Promise.resolve([{ id: 4 }]); } },
    scripting: { insertCSS() { return Promise.resolve(); }, executeScript() { return Promise.resolve([]); } },
    notifications: { create() { return Promise.resolve('id'); }, getAll() { return Promise.resolve({}); } }
  };
  const readonlyBrowser = new Proxy(readonlyHost, {
    set(target, key, value) {
      if (!Object.prototype.hasOwnProperty.call(target, key)) throw new TypeError('readonly namespace ' + String(key));
      target[key] = value;
      return true;
    }
  });
  const readonlySandbox = {
    browser: readonlyBrowser,
    chrome: readonlyBrowser,
    console,
    Promise,
    setTimeout,
    clearTimeout
  };
  readonlySandbox.globalThis = readonlySandbox;
  vm.runInNewContext(source + '\n' + backgroundSource, readonlySandbox, { filename: 'worker.js' });
  assert.equal(readonlyListeners.length, 1);
  function readonlySend(message) {
    let replied = false;
    let replyValue;
    function sendResponse(value) {
      replied = true;
      replyValue = value;
    }
    let handled = false;
    readonlyListeners.forEach(listener => {
      if (listener(message, { tab: { id: 4 } }, sendResponse) === true) handled = true;
    });
    return handled && replied ? replyValue : undefined;
  }
  const readonlyReady = readonlySend({ source: 'rikugan-bg-probe' });
  assert.equal(readonlyReady && readonlyReady.ready, true);
  const readonlyDemo = readonlySend({ type: 'rikugan-probe' });
  assert.equal(readonlyDemo && readonlyDemo.ok, true);
  assert.equal(readonlyDemo.visits, 1);

  // Xcode 16.4 WebKit drops runtime.sendMessage while the background has never
  // loaded (empty listener set). The worker WKWebExtension evaluates is the
  // bridge prepended onto background.js, and only after loadBackgroundContent.
  function patchWorker(text, bridge) {
    const marker = '/* rikugan-extension-bridge */';
    return text.includes(marker) ? text : bridge + '\n' + text;
  }
  const workerSource = patchWorker(backgroundSource, source);
  assert.equal(patchWorker(workerSource, source), workerSource);
  assert.equal(workerSource.indexOf('/* rikugan-extension-bridge */'), 0);
  assert.ok(workerSource.includes('api.runtime.onMessage.addListener'));
  function webkit18Send(state, message) {
    if (ExtensionRuntimeDrop(state)) return undefined;
    let reply;
    let handled = false;
    state.listeners.forEach(listener => {
      let replied = false;
      const value = listener(message, { tab: { id: 4 } }, response => {
        replied = true;
        reply = response;
      });
      if (value === true && replied) handled = true;
    });
    return handled ? reply : undefined;
  }
  function ExtensionRuntimeDrop(state) {
    return !state.loadedOnce && state.listeners.length === 0;
  }
  const cold = { loadedOnce: false, listeners: [] };
  assert.equal(webkit18Send(cold, { type: 'rikugan-probe' }), undefined);
  const woken = {
    loadedOnce: false,
    listeners: [],
    browser: null
  };
  const wokenRuntime = {
    id: 'demo',
    sendMessage() { return Promise.resolve(undefined); },
    onMessage: { addListener(fn) { woken.listeners.push(fn); } },
    connect() { return {}; }
  };
  const wokenHost = {
    runtime: wokenRuntime,
    storage: { local: { get() { return Promise.resolve({}); }, set() { return Promise.resolve(); } } },
    tabs: { query() { return Promise.resolve([{ id: 4 }]); } },
    scripting: { insertCSS() { return Promise.resolve(); }, executeScript() { return Promise.resolve([]); } },
    notifications: { create() { return Promise.resolve('id'); }, getAll() { return Promise.resolve({ 'rikugan-demo': { title: 'Rikugan' } }); } }
  };
  const wokenBrowser = new Proxy(wokenHost, {
    set(target, key, value) {
      if (!Object.prototype.hasOwnProperty.call(target, key)) throw new TypeError('readonly namespace ' + String(key));
      target[key] = value;
      return true;
    }
  });
  const wokenSandbox = {
    browser: wokenBrowser,
    chrome: wokenBrowser,
    console,
    Promise,
    setTimeout,
    clearTimeout
  };
  wokenSandbox.globalThis = wokenSandbox;
  vm.runInNewContext(workerSource, wokenSandbox, { filename: 'background.js' });
  woken.loadedOnce = true;
  assert.equal(woken.listeners.length, 1);
  const wokenReply = webkit18Send(woken, { type: 'rikugan-probe' });
  assert.equal(wokenReply && wokenReply.ok, true);
  assert.equal(wokenReply.visits, 1);

  console.log('PASS: extension bridge scripting and notifications payloads');
})().catch(error => { console.error(error); process.exit(1); });
