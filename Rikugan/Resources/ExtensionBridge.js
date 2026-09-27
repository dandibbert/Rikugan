/* rikugan-extension-bridge */
(function (root) {
  'use strict';
  var MARK = '__rikuganExtensionBridge';

  function runtimeError() {
    var runtime = (root.browser && root.browser.runtime) || (root.chrome && root.chrome.runtime);
    var last = runtime && runtime.lastError;
    return last ? (last.message || String(last)) : '';
  }

  function handler() {
    try { return root.webkit && root.webkit.messageHandlers && root.webkit.messageHandlers.rikuganExtension; }
    catch (error) { return null; }
  }

  function inContentScript() {
    if (typeof window === 'undefined' || typeof window.postMessage !== 'function') return false;
    if (handler()) return false;
    var protocol = '';
    try { protocol = String(location.protocol || ''); } catch (error) { return false; }
    if (protocol.indexOf('extension') !== -1) return false;
    try { return window.top === window; } catch (error) { return false; }
  }

  function nextId() {
    root.__rgExtSeq = (root.__rgExtSeq || 0) + 1;
    return 'rg' + root.__rgExtSeq;
  }

  function withTimeout(promise) {
    if (typeof setTimeout !== 'function') return promise;
    return new Promise(function (resolve, reject) {
      var timer = setTimeout(function () { reject(new Error('extension host timeout')); }, 10000);
      promise.then(function (value) { clearTimeout(timer); resolve(value); }, function (error) { clearTimeout(timer); reject(error); });
    });
  }

  function sendToTab(tabId, payload) {
    var ns = root.browser || root.chrome;
    var message = { source: 'rikugan-extension-host', payload: payload };
    return new Promise(function (resolve, reject) {
      if (!ns || !ns.tabs || typeof ns.tabs.sendMessage !== 'function') { reject(new Error('tabs.sendMessage missing')); return; }
      var finished = false;
      function done(response, error) {
        if (finished) return;
        finished = true;
        if (error) reject(error);
        else if (response && response.error) reject(new Error(response.error));
        else resolve(response ? response.result : undefined);
      }
      try {
        var maybe = ns.tabs.sendMessage(tabId, message, function (response) {
          var last = runtimeError();
          done(response, last ? new Error(last) : null);
        });
        if (maybe && typeof maybe.then === 'function') maybe.then(function (response) { done(response, null); }, function (error) { done(null, error); });
      } catch (error) { done(null, error); }
    });
  }

  function activeTabId() {
    var ns = root.browser || root.chrome;
    return new Promise(function (resolve, reject) {
      if (!ns || !ns.tabs || typeof ns.tabs.query !== 'function') { reject(new Error('tabs.query missing')); return; }
      var finished = false;
      function done(tabs, error) {
        if (finished) return;
        finished = true;
        if (error) reject(error);
        else if (!tabs || !tabs.length || tabs[0].id == null) reject(new Error('no active tab'));
        else resolve(tabs[0].id);
      }
      try {
        var maybe = ns.tabs.query({ active: true, currentWindow: true }, function (tabs) {
          var last = runtimeError();
          done(tabs, last ? new Error(last) : null);
        });
        if (maybe && typeof maybe.then === 'function') maybe.then(function (tabs) { done(tabs, null); }, function (error) { done(null, error); });
      } catch (error) { done(null, error); }
    });
  }

  function deliver(payload) {
    return withTimeout(new Promise(function (resolve, reject) {
      function take(data) {
        if (data && data.error) reject(new Error(data.error));
        else resolve(data ? data.result : undefined);
      }
      var native = handler();
      if (native && typeof native.postMessage === 'function' && !isolatedRequest(payload)) {
        root.__rgExtPending = root.__rgExtPending || {};
        root.__rgExtPending[payload.id] = take;
        native.postMessage(payload);
        return;
      }
      if (inContentScript()) {
        askPage(payload).then(function (result) {
          if (!isolatedRequest(payload)) { resolve(result); return; }
          try { resolve(evalSources(result && result.sources)); }
          catch (error) { reject(error); }
        }, reject);
        return;
      }
      var named = payload.details && payload.details.target && payload.details.target.tabId;
      var send = function (tabId) { sendToTab(tabId, payload).then(resolve, reject); };
      if (named != null && named !== '') send(named);
      else activeTabId().then(send, reject);
    }));
  }

  function finish(promise, callback) {
    if (typeof callback !== 'function') return promise;
    promise.then(function (value) { callback(value); }, function () { callback(); });
  }

  function runtimeId() {
    try {
      var rt = (root.chrome && root.chrome.runtime) || (root.browser && root.browser.runtime);
      return rt && rt.id ? String(rt.id) : '';
    } catch (error) { return ''; }
  }

  function copiedDetails(details) {
    var source = details || {};
    var target = source.target || {};
    var body = { extensionId: runtimeId() };
    if (target.tabId != null) body.target = { tabId: target.tabId };
    else body.target = {};
    if (source.world != null) body.world = source.world;
    if (source.css != null) body.css = String(source.css);
    if (source.code != null) body.code = String(source.code);
    if (typeof source.func === 'function') body.func = Function.prototype.toString.call(source.func);
    else if (typeof source.func === 'string' && source.func) body.func = source.func;
    if (source.args != null) body.args = source.args;
    if (source.files != null) body.files = source.files;
    return body;
  }

  function isolatedRequest(payload) {
    return payload && payload.api === 'scripting.executeScript' && (!payload.details || payload.details.world !== 'MAIN');
  }

  function evalSources(sources) {
    var results = [];
    (sources || []).forEach(function (source) { results.push({ result: (0, eval)(String(source)) }); });
    return results;
  }

  function askPage(payload) {
    return new Promise(function (resolve, reject) {
      function onResult(event) {
        var data = event && event.data;
        if (!data || data.source !== 'rikugan-extension-host-result' || data.id !== payload.id) return;
        window.removeEventListener('message', onResult);
        if (data.error) reject(new Error(data.error));
        else resolve(data.result);
      }
      window.addEventListener('message', onResult);
      window.postMessage({ source: 'rikugan-extension-host', payload: payload }, '*');
    });
  }

  function insertCSS(details) {
    var body = copiedDetails(details);
    var hasFiles = body.files && body.files.length;
    if ((details == null || details.css == null) && !hasFiles) return Promise.reject(new Error('css string or files is required'));
    return deliver({ id: nextId(), api: 'scripting.insertCSS', details: body });
  }

  function executeScript(details) {
    var body = copiedDetails(details);
    var hasFiles = body.files && body.files.length;
    if (!body.func && !body.code && !hasFiles) return Promise.reject(new Error('func, code, or files is required'));
    if (!body.world) body.world = 'ISOLATED';
    return deliver({ id: nextId(), api: 'scripting.executeScript', details: body });
  }

  function notificationOptions(idOrOptions, options) {
    if (typeof idOrOptions === 'string') return { id: idOrOptions, options: options && typeof options === 'object' ? options : {} };
    if (idOrOptions && typeof idOrOptions === 'object') return { id: '', options: idOrOptions };
    return { id: '', options: {} };
  }

  function createNotification(idOrOptions, options, maybeCallback) {
    var callback = typeof options === 'function' ? options : maybeCallback;
    var normalized = notificationOptions(idOrOptions, typeof options === 'function' ? {} : options);
    normalized.extensionId = runtimeId();
    return finish(deliver({ id: nextId(), api: 'notifications.create', details: normalized }), callback);
  }

  function clearNotification(id, callback) {
    return finish(deliver({ id: nextId(), api: 'notifications.clear', details: { id: typeof id === 'string' ? id : '', extensionId: runtimeId() } }), callback);
  }

  function getAllNotifications(callback) {
    return finish(deliver({ id: nextId(), api: 'notifications.getAll', details: { extensionId: runtimeId() } }), callback);
  }

  function updateNotification(id, options, callback) {
    var cb = typeof options === 'function' ? options : callback;
    var opts = options && typeof options === 'object' ? options : {};
    return finish(deliver({ id: nextId(), api: 'notifications.update', details: { id: typeof id === 'string' ? id : '', options: opts, extensionId: runtimeId() } }), cb);
  }

  function notificationEvent() {
    var list = [];
    return {
      addListener: function (fn) { if (typeof fn === 'function' && list.indexOf(fn) < 0) list.push(fn); },
      removeListener: function (fn) { var index = list.indexOf(fn); if (index >= 0) list.splice(index, 1); },
      hasListener: function (fn) { return list.indexOf(fn) >= 0; },
      _emit: function () {
        var args = Array.prototype.slice.call(arguments);
        list.slice().forEach(function (fn) { try { fn.apply(null, args); } catch (error) {} });
      }
    };
  }

  function emitNotification(event) {
    if (!event) return;
    var id = event.notificationId || event.notificationID;
    var seen = [];
    [root.chrome, root.browser].forEach(function (ns) {
      if (!ns || !ns.notifications || seen.indexOf(ns.notifications) >= 0) return;
      seen.push(ns.notifications);
      if (event.type === 'clicked' && ns.notifications.onClicked && typeof ns.notifications.onClicked._emit === 'function') ns.notifications.onClicked._emit(id);
      if (event.type === 'button' && ns.notifications.onButtonClicked && typeof ns.notifications.onButtonClicked._emit === 'function') ns.notifications.onButtonClicked._emit(id, event.buttonIndex);
    });
  }

  function pollNotifications() {
    return deliver({ id: nextId(), api: 'notifications.poll', details: { extensionId: runtimeId() } }).then(function (events) {
      if (!Array.isArray(events)) return [];
      events.forEach(emitNotification);
      return events;
    }, function () { return []; });
  }

  function namespaces() {
    if (!root.chrome) root.chrome = root.browser || {};
    if (!root.browser) root.browser = root.chrome;
    var list = [root.chrome];
    if (root.browser !== root.chrome) list.push(root.browser);
    return list;
  }

  function bucket(list, key) {
    var found = [];
    list.forEach(function (ns) {
      if (!ns[key] || typeof ns[key] !== 'object') ns[key] = {};
      if (found.indexOf(ns[key]) < 0) found.push(ns[key]);
    });
    return found;
  }

  function fill(list, name, fn) {
    list.forEach(function (api) { if (typeof api[name] !== 'function') api[name] = fn; });
  }

  function fillEvent(list, name) {
    list.forEach(function (api) {
      if (!api[name] || typeof api[name].addListener !== 'function') api[name] = notificationEvent();
    });
  }

  function relay() {
    if (!inContentScript()) return;
    var runtime = (root.browser && root.browser.runtime) || (root.chrome && root.chrome.runtime);
    if (!runtime || !runtime.onMessage || typeof runtime.onMessage.addListener !== 'function' || runtime.__rgHostRelay) return;
    runtime.__rgHostRelay = true;
    runtime.onMessage.addListener(function (message, sender, sendResponse) {
      if (!message || message.source !== 'rikugan-extension-host' || !message.payload) return;
      var payload = message.payload;
      if (isolatedRequest(payload)) {
        askPage(payload).then(function (prepared) {
          try { sendResponse({ result: evalSources(prepared && prepared.sources) }); }
          catch (error) { sendResponse({ error: String(error && error.message || error) }); }
        }, function (error) { sendResponse({ error: String(error && error.message || error) }); });
        return true;
      }
      function onResult(event) {
        var data = event && event.data;
        if (!data || data.source !== 'rikugan-extension-host-result' || data.id !== payload.id) return;
        window.removeEventListener('message', onResult);
        if (typeof sendResponse === 'function') sendResponse(data.error ? { error: data.error } : { result: data.result });
      }
      window.addEventListener('message', onResult);
      window.postMessage({ source: 'rikugan-extension-host', payload: payload }, '*');
      return true;
    });
  }

  function installRikuganExtensionBridge(target) {
    var host = target || root;
    if (host[MARK]) return host.chrome || host.browser;
    if (!host.chrome && !host.browser) return null;
    host[MARK] = true;
    var list = namespaces();
    fill(bucket(list, 'scripting'), 'insertCSS', insertCSS);
    fill(bucket(list, 'scripting'), 'executeScript', executeScript);
    var notes = bucket(list, 'notifications');
    fill(notes, 'create', createNotification);
    fill(notes, 'clear', clearNotification);
    fill(notes, 'getAll', getAllNotifications);
    fill(notes, 'update', updateNotification);
    fillEvent(notes, 'onClicked');
    fillEvent(notes, 'onButtonClicked');
    relay();
    if (typeof window === 'undefined' && !handler() && typeof setInterval === 'function' && !root.__rikuganNotificationPoll) {
      root.__rikuganNotificationPoll = true;
      var pollTimer = setInterval(function () { pollNotifications(); }, 1000);
      if (pollTimer && typeof pollTimer.unref === 'function') pollTimer.unref();
    }
    root.__rikuganPollNotifications = pollNotifications;
    return host.chrome || host.browser;
  }

  root.installRikuganExtensionBridge = installRikuganExtensionBridge;
  if (!installRikuganExtensionBridge(root) && typeof setInterval === 'function') {
    var tries = 0;
    var timer = setInterval(function () {
      tries += 1;
      if (installRikuganExtensionBridge(root) || tries > 40) clearInterval(timer);
    }, 50);
  }
})(typeof globalThis !== 'undefined' ? globalThis : this);
