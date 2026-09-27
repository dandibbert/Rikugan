const api = typeof browser !== 'undefined' ? browser : chrome;

function callWith(target, name, args) {
  return new Promise((resolve, reject) => {
    const fn = target && target[name];
    if (typeof fn !== 'function') { reject(new Error('missing api')); return; }
    let settled = false;
    function done(value) {
      if (settled) return;
      settled = true;
      resolve(value);
    }
    let result;
    try { result = fn.apply(target, args); }
    catch (error) { reject(error); return; }
    if (result && typeof result.then === 'function') { result.then(done, reject); return; }
    if (result !== undefined) { done(result); return; }
    try { fn.apply(target, args.concat([value => done(value)])); }
    catch (error) { reject(error); }
  });
}

function deadline(work, ms) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('timeout')), ms);
    Promise.resolve(work).then(value => { clearTimeout(timer); resolve(value); }, error => { clearTimeout(timer); reject(error); });
  });
}

let visits = 0;
try {
  const storage = api.storage && api.storage.local;
  const pending = storage && typeof storage.get === 'function' ? storage.get.call(storage, 'visits') : null;
  if (pending && typeof pending.then === 'function') pending.then(result => { visits = (result && result.visits) || 0; }, () => {});
} catch (error) {}

function onRuntimeMessage(message, sender, sendResponse) {
  if (message && message.source === 'rikugan-bg-probe') {
    if (typeof sendResponse === 'function') {
      sendResponse({ ready: true });
      return true;
    }
    return Promise.resolve({ ready: true });
  }
  if (!message || message.type !== 'rikugan-probe') return;
  visits += 1;
  const count = visits;
  const payload = { ok: true, visits: count };
  try {
    const storage = api.storage && api.storage.local;
    const wrote = storage && typeof storage.set === 'function' ? storage.set.call(storage, { visits: count }) : null;
    if (wrote && typeof wrote.catch === 'function') wrote.catch(() => {});
  } catch (error) {}
  const tabId = sender && sender.tab && sender.tab.id;
  const target = {};
  if (tabId != null) target.tabId = tabId;
  const scripting = api.scripting;
  const notifications = api.notifications;
  const tabs = api.tabs;
  const located = tabId != null
    ? Promise.resolve(target)
    : deadline(callWith(tabs, 'query', [{ active: true, currentWindow: true }]), 2000).then(list => {
      const id = list && list[0] && list[0].id;
      if (id != null) target.tabId = id;
      return target;
    }).catch(() => target);
  located.then(() => deadline(callWith(scripting, 'insertCSS', [{ target, css: '#rikugan-scripting-result{outline:1px solid transparent}' }]), 2000))
    .then(() => deadline(callWith(scripting, 'executeScript', [{
      target,
      func: function () {
        var node = document.getElementById('rikugan-scripting-result') || document.createElement('div');
        node.id = 'rikugan-scripting-result';
        node.textContent = '脚本注入成功';
        (document.body || document.documentElement).prepend(node);
      }
    }]), 2000))
    .catch(() => {})
    .then(() => confirmNotification(notifications))
    .then(all => {
      if (!all || !all['rikugan-demo']) return null;
      return deadline(callWith(scripting, 'executeScript', [{
        target,
        func: function () {
          var node = document.getElementById('rikugan-notification-result') || document.createElement('div');
          node.id = 'rikugan-notification-result';
          node.textContent = '通知已创建';
          (document.body || document.documentElement).prepend(node);
        }
      }]), 2000);
    })
    .catch(() => {});
  if (typeof sendResponse === 'function') {
    sendResponse(payload);
    return true;
  }
  return Promise.resolve(payload);
}
// Xcode 16.4's WebExtensionAPINotifications only has onClicked and onButtonClicked.
// create and getAll are not functions, so the native call rejects before the page
// can show 通知已创建. The app records a notification through rikuganExtension.
function extensionRuntimeId() {
  try { return (api.runtime && api.runtime.id) || ''; } catch (error) { return ''; }
}
function hostCall(apiName, details) {
  return new Promise((resolve, reject) => {
    let native = null;
    try { native = webkit && webkit.messageHandlers && webkit.messageHandlers.rikuganExtension; }
    catch (error) { native = null; }
    if (!native || typeof native.postMessage !== 'function') { reject(new Error('no extension host')); return; }
    const id = 'rg' + Math.random().toString(36).slice(2);
    const pending = globalThis.__rgExtPending || (globalThis.__rgExtPending = {});
    const timer = setTimeout(() => { delete pending[id]; reject(new Error('extension host timeout')); }, 8000);
    pending[id] = data => {
      clearTimeout(timer);
      delete pending[id];
      if (data && data.error) reject(new Error(String(data.error)));
      else resolve(data ? data.result : undefined);
    };
    try { native.postMessage({ id: id, api: apiName, details: details }); }
    catch (error) { clearTimeout(timer); delete pending[id]; reject(error); }
  });
}
function confirmNotification(notifications) {
  const options = { type: 'basic', title: 'Rikugan', message: '通知已创建' };
  const extensionId = extensionRuntimeId();
  const nativeCreate = notifications && typeof notifications.create === 'function';
  const nativeList = notifications && typeof notifications.getAll === 'function';
  const created = nativeCreate
    ? deadline(callWith(notifications, 'create', ['rikugan-demo', options]), 2000)
    : hostCall('notifications.create', { id: 'rikugan-demo', options: options, extensionId: extensionId });
  return created.then(identifier => {
    if (nativeList) return deadline(callWith(notifications, 'getAll', []), 2000);
    if (nativeCreate) return identifier ? { 'rikugan-demo': { message: '通知已创建' } } : null;
    return hostCall('notifications.getAll', { extensionId: extensionId });
  });
}
// The API test loads `<script type="module" src="background.js">` from its
// generated background page. This app's copy of that page still finished
// didFinishDocumentLoad (the install alert appeared) and the content script
// still got an empty sendMessage reply, so that module did not leave a
// listener. A classic script in background.html is not a CORS module fetch.
// Register once, after the parser has the document, without clearing it.
function registerRuntimeListener() {
  const events = api && api.runtime && api.runtime.onMessage;
  if (!events || typeof events.addListener !== 'function') return false;
  events.addListener(onRuntimeMessage);
  return true;
}
function bootBackground() {
  if (registerRuntimeListener()) return;
  let reloaded = false;
  try { reloaded = sessionStorage.getItem('rikugan-bg-reload') === '1'; } catch (error) {}
  if (reloaded || typeof location === 'undefined' || typeof location.reload !== 'function') return;
  try { sessionStorage.setItem('rikugan-bg-reload', '1'); } catch (error) {}
  location.reload();
}
if (typeof document !== 'undefined' && document.readyState === 'loading' && typeof document.addEventListener === 'function') document.addEventListener('DOMContentLoaded', bootBackground);
else bootBackground();
