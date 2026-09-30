// Rikugan Chrome MV3 compatibility runtime.
// Injected into: extension content-script worlds (ctx = "content"), extension pages such as popup /
// options (ctx = "page") and the hidden background runtime (ctx = "background").
// Every call is bridged to the native ChromeAPIBridge through WKScriptMessageHandlerWithReply.
(function (cfg) {
  'use strict';
  if (!cfg) return;
  const g = globalThis;
  if (g.__rikuganChrome && g.__rikuganChrome.extId === cfg.extId) return;
  if (cfg.ctx !== 'content' && typeof location !== 'undefined' && !String(location.href).startsWith(cfg.baseURL)) return;

  const handler = g.webkit && g.webkit.messageHandlers && g.webkit.messageHandlers[cfg.handler];
  const postRaw = handler ? handler.postMessage.bind(handler) : null;
  const jsonable = (v) => {
    if (v === undefined) return null;
    try { return JSON.parse(JSON.stringify(v, (k, x) => (typeof x === 'function' ? undefined : x))); } catch (_) { return null; }
  };
  const bridge = (api, args) => {
    if (!postRaw) return Promise.reject(new Error('Rikugan extension bridge unavailable'));
    return postRaw({ ch: 'chrome', ext: cfg.extId, ctx: cfg.ctx, api, args: jsonable(args === undefined ? {} : args), frame: contentFrameToken });
  };

  // ---- lastError / callback+promise dual mode -------------------------------------------------
  let currentLastError;
  const withLastError = (error, fn) => {
    currentLastError = { message: String(error && error.message || error) };
    try { fn(); } finally { currentLastError = undefined; }
  };
  const toError = (e) => (e instanceof Error ? e : new Error(String(e && e.message || e)));
  // Wrap an async implementation so it supports both callbacks and promises (Chrome MV3 style).
  const api = (impl) => function (...args) {
    let cb = null;
    if (args.length && typeof args[args.length - 1] === 'function') cb = args.pop();
    let p;
    try { p = Promise.resolve(impl.apply(this, args)); } catch (e) { p = Promise.reject(e); }
    if (cb) {
      p.then((r) => { try { cb(r); } catch (e) { console.error(e); } },
        (e) => withLastError(toError(e), () => { try { cb(); } catch (err) { console.error(err); } }));
      return undefined;
    }
    return p.catch((e) => { throw toError(e); });
  };
  const call = (name) => api((...args) => bridge(name, { args }));

  const unsupportedError = (name) => new Error('Unsupported API: chrome.' + name + ' is not available in Rikugan');
  const reportedUnsupported = new Set();
  const unsupportedFn = (name) => Object.assign(function (...args) {
    const error = unsupportedError(name);
    console.warn('[Rikugan]', error.message);
    if (!reportedUnsupported.has(name)) { reportedUnsupported.add(name); bridge('runtime._reportUnsupported', { api: name }).catch(() => {}); }
    const cb = args.length && typeof args[args.length - 1] === 'function' ? args[args.length - 1] : null;
    if (cb) { withLastError(error, () => cb()); return undefined; }
    return Promise.reject(error);
  }, { __rikuganUnsupported: true });

  // ---- Events ---------------------------------------------------------------------------------
  class RkEvent {
    constructor(name) { this._name = name; this._listeners = []; }
    addListener(fn, filter) {
      if (typeof fn !== 'function') throw new TypeError('Listener must be a function');
      if (filter !== undefined && filter !== null) {
        const keys = Object.keys(filter);
        if (keys.some((k) => k !== 'url')) throw new TypeError(this._name + ': event filter keys ' + keys.join(', ') + ' are not supported in Rikugan');
      }
      if (!this.hasListener(fn)) this._listeners.push({ fn, filter });
      if (!RkEvent.subscribed.has(this._name)) { RkEvent.subscribed.add(this._name); bridge('events.subscribe', { event: this._name }).catch(() => {}); }
    }
    removeListener(fn) { this._listeners = this._listeners.filter((l) => l.fn !== fn); }
    hasListener(fn) { return this._listeners.some((l) => l.fn === fn); }
    hasListeners() { return this._listeners.length > 0; }
    addRules() { return unsupportedFn(this._name + '.addRules').apply(null, arguments); }
    getRules() { return unsupportedFn(this._name + '.getRules').apply(null, arguments); }
    removeRules() { return unsupportedFn(this._name + '.removeRules').apply(null, arguments); }
    _dispatch(args) {
      const results = [];
      for (const l of this._listeners.slice()) {
        if (l.filter && !RkEvent.matchesFilter(l.filter, args && args[0])) continue;
        try { results.push(l.fn.apply(null, args)); } catch (e) { console.error('[' + this._name + ']', e); }
      }
      return results;
    }
    // Event filters: `{ url: [UrlFilter, ...] }` (webNavigation) — any filter in the list matches.
    // Other filter keys are not understood and are rejected at registration, not ignored.
    static matchesFilter(filter, details) {
      const list = filter && filter.url;
      if (!Array.isArray(list) || !list.length) return true;
      let u;
      try { u = new URL(details && details.url); } catch (_) { return false; }
      return list.some((f) => RkEvent.matchesUrlFilter(f || {}, u));
    }
    static matchesUrlFilter(f, u) {
      const host = u.hostname, path = u.pathname, query = u.search.replace(/^\?/, ''), full = u.href;
      const noFrag = full.split('#')[0];
      const checks = {
        hostContains: (v) => ('.' + host).includes(v), hostEquals: (v) => host === v, hostPrefix: (v) => host.startsWith(v),
        hostSuffix: (v) => host.endsWith(v) || ('.' + host).endsWith(v),
        pathContains: (v) => path.includes(v), pathEquals: (v) => path === v, pathPrefix: (v) => path.startsWith(v), pathSuffix: (v) => path.endsWith(v),
        queryContains: (v) => query.includes(v), queryEquals: (v) => query === v, queryPrefix: (v) => query.startsWith(v), querySuffix: (v) => query.endsWith(v),
        urlContains: (v) => noFrag.includes(v), urlEquals: (v) => noFrag === v, urlPrefix: (v) => noFrag.startsWith(v), urlSuffix: (v) => noFrag.endsWith(v),
        urlMatches: (v) => new RegExp(v).test(noFrag), originAndPathMatches: (v) => new RegExp(v).test(u.origin + path),
        schemes: (v) => v.includes(u.protocol.replace(/:$/, '')),
        ports: (v) => { const port = Number(u.port || (u.protocol === 'https:' ? 443 : u.protocol === 'http:' ? 80 : 0));
          return v.some((p) => Array.isArray(p) ? port >= p[0] && port <= p[1] : port === p); },
      };
      return Object.keys(f).every((k) => checks[k] ? checks[k](f[k]) : false);
    }
  }
  RkEvent.subscribed = new Set();
  const events = new Map();
  const ev = (name) => { if (!events.has(name)) events.set(name, new RkEvent(name)); return events.get(name); };

  // Proxy: supported namespace; unknown members become explicit Unsupported stubs instead of undefined.
  // Events that Rikugan cannot deliver: listeners are accepted (so extension start-up does not
  // crash) but the registration is reported as Unsupported and the object is marked.
  const unsupportedEvent = (name) => {
    const warn = unsupportedFn(name + '.addListener');
    return { __rikuganUnsupported: true, addListener() { warn().catch(() => {}); }, removeListener() {}, hasListener: () => false, hasListeners: () => false };
  };
  // An unknown member is callable (rejects as Unsupported) and also usable as a namespace, so
  // chrome.privacy.network.networkPredictionEnabled.set(...) reports Unsupported instead of
  // throwing a TypeError on undefined.
  const unsupportedMember = (path) => new Proxy(unsupportedFn(path), {
    get(t, prop) {
      if (prop in t || typeof prop === 'symbol' || prop === 'then' || prop === 'toJSON') return t[prop];
      if (/^on[A-Z]/.test(prop)) return unsupportedEvent(path + '.' + prop);
      if (/^[A-Z_0-9]+$/.test(prop)) return undefined;
      return unsupportedMember(path + '.' + prop);
    },
  });
  const guarded = (ns, target) => new Proxy(target, {
    get(t, prop) {
      if (prop in t || typeof prop === 'symbol' || prop === 'then' || prop === 'toJSON') return t[prop];
      if (ns === '') return unsupportedNamespace(prop);
      if (/^on[A-Z]/.test(prop)) { const e = unsupportedEvent(ns + '.' + prop); t[prop] = e; return e; }
      if (/^[A-Z_0-9]+$/.test(prop)) return undefined;
      return unsupportedMember(ns + '.' + prop);
    },
  });
  const unsupportedNamespace = (ns) => guarded(ns, {});
  // chrome.tts.speak({onEvent}) callbacks, keyed by utterance id (events arrive as 'tts._event').
  const ttsCallbacks = new Map();

  // ---- Messaging --------------------------------------------------------------------------------
  const portsById = new Map();
  class Port {
    constructor(id, name, sender) {
      this.name = name || '';
      this.sender = sender || undefined;
      this._id = id;
      this._connected = true;
      this.onMessage = new RkEvent('port.onMessage');
      this.onDisconnect = new RkEvent('port.onDisconnect');
      portsById.set(id, this);
    }
    postMessage(message) {
      if (!this._connected) throw new Error('Attempting to use a disconnected port object');
      bridge('port.post', { portId: this._id, message: jsonable(message) }).catch((e) => console.warn('[Rikugan] port.postMessage', e));
    }
    disconnect() {
      if (!this._connected) return;
      this._connected = false;
      portsById.delete(this._id);
      bridge('port.disconnect', { portId: this._id }).catch(() => {});
    }
  }
  const uuid = () => (g.crypto && crypto.randomUUID ? crypto.randomUUID() : 'p' + Math.random().toString(36).slice(2) + Date.now().toString(36));
  // Identifies this content-script document (frame) in native messages; URLs are not unique.
  var contentFrameToken = cfg.ctx === 'content' ? uuid() : null;
  const connect = (target, info) => {
    const portId = uuid();
    const port = new Port(portId, info && info.name);
    bridge('runtime.connect', Object.assign({ portId, name: port.name }, target)).catch((e) => {
      port._connected = false;
      withLastError(e, () => port.onDisconnect._dispatch([port]));
    });
    return port;
  };
  const onMessage = ev('runtime.onMessage');
  const onConnect = ev('runtime.onConnect');
  const deliverMessage = (message, sender) => {
    const listeners = onMessage._listeners.slice();
    if (!listeners.length) return Promise.resolve({ none: true });
    return new Promise((resolve) => {
      let settled = false;
      let pending = false;
      const sendResponse = (response) => {
        if (settled) return;
        settled = true;
        resolve({ response: response === undefined ? null : jsonable(response), has: true });
      };
      for (const l of listeners) {
        let ret;
        try { ret = l.fn(message, sender, sendResponse); } catch (e) { console.error('[runtime.onMessage]', e); }
        if (ret === true) pending = true;
        else if (ret && typeof ret.then === 'function') {
          pending = true;
          ret.then((v) => sendResponse(v), (e) => { if (!settled) { settled = true; resolve({ error: String(e && e.message || e) }); } });
        }
      }
      if (!pending && !settled) resolve({ none: true, listened: true });
    });
  };

  // ---- Storage ----------------------------------------------------------------------------------
  const storageArea = (area) => {
    const obj = {
      get: api(async (keys) => {
        let request = keys;
        let defaults = null;
        if (keys && typeof keys === 'object' && !Array.isArray(keys)) { defaults = keys; request = Object.keys(keys); }
        else if (typeof keys === 'string') request = [keys];
        else if (keys === undefined || keys === null) request = null;
        const raw = await bridge('storage.get', { area, keys: request });
        const out = {};
        if (defaults) for (const k of Object.keys(defaults)) out[k] = defaults[k];
        for (const k of Object.keys(raw || {})) { try { out[k] = JSON.parse(raw[k]); } catch (_) {} }
        return out;
      }),
      set: api(async (items) => {
        if (!items || typeof items !== 'object') throw new Error('storage.set expects an object');
        const encoded = {};
        for (const k of Object.keys(items)) { if (items[k] !== undefined) encoded[k] = JSON.stringify(items[k]); }
        await bridge('storage.set', { area, items: encoded });
      }),
      remove: api(async (keys) => { await bridge('storage.remove', { area, keys: typeof keys === 'string' ? [keys] : keys }); }),
      clear: api(async () => { await bridge('storage.clear', { area }); }),
      getBytesInUse: api(async (keys) => bridge('storage.getBytesInUse', { area, keys: typeof keys === 'string' ? [keys] : (keys || null) })),
      getKeys: api(async () => bridge('storage.getKeys', { area })),
      setAccessLevel: area === 'session' ? api(async (options) => {
        const level = options && options.accessLevel;
        if (level !== 'TRUSTED_CONTEXTS' && level !== 'TRUSTED_AND_UNTRUSTED_CONTEXTS') throw new Error('Invalid accessLevel');
        await bridge('storage.setAccessLevel', { area, accessLevel: level });
      }) : unsupportedFn('storage.' + area + '.setAccessLevel'),
      onChanged: ev('storage.' + area + '.onChanged'),
      QUOTA_BYTES: area === 'sync' ? 102400 : area === 'session' ? 10485760 : 10485760,
    };
    if (area === 'sync') Object.assign(obj, { QUOTA_BYTES_PER_ITEM: 8192, MAX_ITEMS: 512, MAX_WRITE_OPERATIONS_PER_HOUR: 1800, MAX_WRITE_OPERATIONS_PER_MINUTE: 120 });
    if (area === 'managed') { obj.set = unsupportedFn('storage.managed.set'); obj.remove = unsupportedFn('storage.managed.remove'); obj.clear = unsupportedFn('storage.managed.clear'); }
    return guarded('storage.' + area, obj);
  };
  const storage = guarded('storage', {
    local: storageArea('local'), sync: storageArea('sync'), session: storageArea('session'), managed: storageArea('managed'),
    onChanged: ev('storage.onChanged'),
  });

  // ---- i18n ----------------------------------------------------------------------------------------
  const messages = cfg.messages || {};
  const getMessage = (name, substitutions) => {
    const key = String(name).toLowerCase();
    const subs = substitutions === undefined ? [] : (Array.isArray(substitutions) ? substitutions : [substitutions]).map(String);
    const special = { '@@extension_id': cfg.extId, '@@ui_locale': cfg.uiLocale, '@@bidi_dir': 'ltr', '@@bidi_reversed_dir': 'rtl', '@@bidi_start_edge': 'left', '@@bidi_end_edge': 'right' };
    if (key in special) return special[key];
    const entry = messages[key];
    if (!entry || typeof entry.message !== 'string') return '';
    const numbered = (text) => text.replace(/\$(\d)/g, (m, d) => (subs[Number(d) - 1] !== undefined ? subs[Number(d) - 1] : ''));
    let text = entry.message;
    const placeholders = entry.placeholders || {};
    text = text.replace(/\$([A-Za-z0-9_@]+)\$/g, (m, n) => {
      const ph = Object.keys(placeholders).find((k) => k.toLowerCase() === n.toLowerCase());
      return ph ? numbered(String(placeholders[ph].content || '')) : m;
    });
    return numbered(text).replace(/\$\$/g, '$');
  };
  const i18n = guarded('i18n', {
    getMessage,
    getUILanguage: () => cfg.uiLanguage,
    getAcceptLanguages: api(async () => cfg.acceptLanguages),
    detectLanguage: api(async (text) => bridge('i18n.detectLanguage', { text: String(text).slice(0, 5000) })),
  });

  // ---- runtime -------------------------------------------------------------------------------------
  const getURL = (path) => cfg.baseURL + String(path || '').replace(/^\//, '');
  const runtime = {
    id: cfg.extId,
    getURL,
    getManifest: () => JSON.parse(JSON.stringify(cfg.manifest)),
    get lastError() { return currentLastError; },
    sendMessage: api(async (...args) => {
      // sendMessage(extensionId?, message, options?)
      let message = args[0];
      if (args.length >= 2 && typeof args[0] === 'string' && /^[a-p]{32}$/.test(args[0])) {
        if (args[0] !== cfg.extId) throw new Error('Could not establish connection. Receiving end does not exist.');
        message = args[1];
      } else if (args.length >= 2 && (args[0] === null || args[0] === undefined)) {
        message = args[1];
      }
      const r = await bridge('runtime.sendMessage', { message: jsonable(message) });
      return r === null ? undefined : r;
    }),
    connect: (...args) => {
      let info = args[0];
      if (typeof args[0] === 'string') {
        info = args[1];
        if (args[0] !== cfg.extId) {
          // Other extensions / web pages are not reachable: a port that disconnects at once.
          const port = new Port(uuid(), info && info.name);
          port._connected = false;
          portsById.delete(port._id);
          setTimeout(() => withLastError(new Error('Could not establish connection. Receiving end does not exist.'),
            () => port.onDisconnect._dispatch([port])), 0);
          return port;
        }
      }
      return connect({ target: 'extension' }, info || {});
    },
    onMessage,
    onConnect,
    onInstalled: ev('runtime.onInstalled'),
    onStartup: ev('runtime.onStartup'),
    onSuspend: ev('runtime.onSuspend'),
    onSuspendCanceled: ev('runtime.onSuspendCanceled'),
    onUpdateAvailable: ev('runtime.onUpdateAvailable'),
    onMessageExternal: ev('runtime.onMessageExternal'),
    onConnectExternal: ev('runtime.onConnectExternal'),
    onUserScriptMessage: ev('runtime.onUserScriptMessage'),
    PlatformOs: { MAC: 'mac', WIN: 'win', ANDROID: 'android', CROS: 'cros', LINUX: 'linux', OPENBSD: 'openbsd', FUCHSIA: 'fuchsia', IOS: 'ios' },
    PlatformArch: { ARM: 'arm', ARM64: 'arm64', X86_32: 'x86-32', X86_64: 'x86-64' },
    OnInstalledReason: { INSTALL: 'install', UPDATE: 'update', CHROME_UPDATE: 'chrome_update', SHARED_MODULE_UPDATE: 'shared_module_update' },
    ContextType: { TAB: 'TAB', POPUP: 'POPUP', BACKGROUND: 'BACKGROUND', OFFSCREEN_DOCUMENT: 'OFFSCREEN_DOCUMENT', SIDE_PANEL: 'SIDE_PANEL' },
  };
  if (cfg.ctx !== 'content') {
    Object.assign(runtime, {
      openOptionsPage: call('runtime.openOptionsPage'),
      setUninstallURL: api(async () => undefined),
      reload: () => { bridge('runtime.reload', {}).catch(() => {}); },
      requestUpdateCheck: unsupportedFn('runtime.requestUpdateCheck'),
      getPlatformInfo: api(async () => ({ os: 'ios', arch: 'arm64', nacl_arch: 'arm' })),
      getBackgroundPage: unsupportedFn('runtime.getBackgroundPage'),
      getContexts: call('runtime.getContexts'),
      sendNativeMessage: unsupportedFn('runtime.sendNativeMessage'),
      connectNative: unsupportedFn('runtime.connectNative'),
      restart: unsupportedFn('runtime.restart'),
      getPackageDirectoryEntry: unsupportedFn('runtime.getPackageDirectoryEntry'),
    });
  }

  const chrome = {};
  chrome.runtime = guarded('runtime', runtime);
  chrome.storage = storage;
  chrome.i18n = i18n;
  chrome.extension = guarded('extension', {
    getURL,
    inIncognitoContext: false,
    getViews: () => [],
    getBackgroundPage: () => null,
    isAllowedIncognitoAccess: api(async () => false),
    isAllowedFileSchemeAccess: api(async () => false),
    sendMessage: chrome.runtime.sendMessage,
    onMessage,
  });

  if (cfg.ctx === 'content') {
    // Content scripts: resources of the extension are read through the bridge, avoiding mixed-content
    // restrictions on the custom scheme inside https pages.
    const nativeFetch = g.fetch ? g.fetch.bind(g) : null;
    if (nativeFetch) {
      g.fetch = async function (input, init) {
        const url = typeof input === 'string' ? input : (input && input.url) || String(input);
        if (url.startsWith(cfg.baseURL)) {
          const r = await bridge('runtime._readResource', { path: url.slice(cfg.baseURL.length).split(/[?#]/)[0] });
          const bin = atob(r.base64);
          const bytes = new Uint8Array(bin.length);
          for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
          return new Response(bytes, { status: 200, headers: { 'Content-Type': r.mime } });
        }
        return nativeFetch(input, init);
      };
    }
  } else {
    // ---- tabs / windows ------------------------------------------------------------------------
    chrome.tabs = guarded('tabs', {
      TAB_ID_NONE: -1,
      MAX_CAPTURE_VISIBLE_TAB_CALLS_PER_SECOND: 2,
      query: call('tabs.query'),
      get: call('tabs.get'),
      getCurrent: call('tabs.getCurrent'),
      create: call('tabs.create'),
      update: call('tabs.update'),
      remove: call('tabs.remove'),
      reload: call('tabs.reload'),
      duplicate: call('tabs.duplicate'),
      goBack: call('tabs.goBack'),
      goForward: call('tabs.goForward'),
      captureVisibleTab: call('tabs.captureVisibleTab'),
      detectLanguage: call('tabs.detectLanguage'),
      move: call('tabs.move'), discard: call('tabs.discard'), highlight: call('tabs.highlight'),
      getZoom: api(async () => 1),
      getZoomSettings: api(async () => ({ mode: 'automatic', scope: 'per-origin', defaultZoomFactor: 1 })),
      sendMessage: api(async (tabId, message, options) => {
        const r = await bridge('tabs.sendMessage', { tabId, message: jsonable(message), frameId: options && options.frameId, documentId: options && options.documentId });
        return r === null ? undefined : r;
      }),
      connect: (tabId, info) => connect({ target: 'tab', tabId, frameId: info && info.frameId }, info || {}),
      executeScript: api(async (tabId, details) => {
        if (typeof tabId === 'object') { details = tabId; tabId = undefined; }
        return (await bridge('scripting.executeScript', { target: { tabId, allFrames: !!details.allFrames }, files: details.file ? [details.file] : null, code: details.code || null })).map((r) => r.result);
      }),
      insertCSS: api(async (tabId, details) => {
        if (typeof tabId === 'object') { details = tabId; tabId = undefined; }
        await bridge('scripting.insertCSS', { target: { tabId, allFrames: !!details.allFrames }, css: details.code || null, files: details.file ? [details.file] : null });
      }),
      onCreated: ev('tabs.onCreated'), onUpdated: ev('tabs.onUpdated'), onActivated: ev('tabs.onActivated'), onRemoved: ev('tabs.onRemoved'),
      onReplaced: ev('tabs.onReplaced'), onMoved: ev('tabs.onMoved'), onHighlighted: ev('tabs.onHighlighted'), onAttached: ev('tabs.onAttached'),
      onDetached: ev('tabs.onDetached'), onZoomChange: ev('tabs.onZoomChange'),
      TabStatus: { UNLOADED: 'unloaded', LOADING: 'loading', COMPLETE: 'complete' },
    });
    chrome.windows = guarded('windows', {
      WINDOW_ID_NONE: -1, WINDOW_ID_CURRENT: -2,
      get: call('windows.get'), getCurrent: call('windows.getCurrent'), getLastFocused: call('windows.getLastFocused'),
      getAll: call('windows.getAll'), create: call('windows.create'), update: call('windows.update'),
      onCreated: ev('windows.onCreated'), onRemoved: ev('windows.onRemoved'), onFocusChanged: ev('windows.onFocusChanged'), onBoundsChanged: ev('windows.onBoundsChanged'),
    });

    // ---- scripting -----------------------------------------------------------------------------
    chrome.scripting = guarded('scripting', {
      ExecutionWorld: { ISOLATED: 'ISOLATED', MAIN: 'MAIN' },
      StyleOrigin: { AUTHOR: 'AUTHOR', USER: 'USER' },
      executeScript: api(async (injection) => {
        if (!injection || !injection.target) throw new Error('scripting.executeScript: target is required');
        const payload = { target: injection.target, world: injection.world || 'ISOLATED', files: injection.files || null };
        if (typeof injection.func === 'function') { payload.func = injection.func.toString(); payload.args = jsonable(injection.args || []); }
        else if (typeof injection.function === 'function') { payload.func = injection.function.toString(); payload.args = jsonable(injection.args || []); }
        return bridge('scripting.executeScript', payload);
      }),
      insertCSS: api(async (injection) => { await bridge('scripting.insertCSS', injection); }),
      removeCSS: api(async (injection) => { await bridge('scripting.removeCSS', injection); }),
      registerContentScripts: call('scripting.registerContentScripts'),
      getRegisteredContentScripts: call('scripting.getRegisteredContentScripts'),
      unregisterContentScripts: call('scripting.unregisterContentScripts'),
      updateContentScripts: call('scripting.updateContentScripts'),
    });

    // ---- permissions -------------------------------------------------------------------------
    chrome.permissions = guarded('permissions', {
      contains: call('permissions.contains'), getAll: call('permissions.getAll'), request: call('permissions.request'),
      remove: call('permissions.remove'), addHostAccessRequest: unsupportedFn('permissions.addHostAccessRequest'),
      onAdded: ev('permissions.onAdded'), onRemoved: ev('permissions.onRemoved'),
    });

    // ---- action ----------------------------------------------------------------------------------
    const iconToData = async (details) => {
      if (!details || !details.imageData) return details;
      const out = Object.assign({}, details);
      const toURL = (img) => {
        const canvas = document.createElement('canvas');
        canvas.width = img.width; canvas.height = img.height;
        canvas.getContext('2d').putImageData(img, 0, 0);
        return canvas.toDataURL('image/png');
      };
      try {
        if (typeof ImageData !== 'undefined' && details.imageData instanceof ImageData) out.imageDataURL = { '32': toURL(details.imageData) };
        else { out.imageDataURL = {}; for (const k of Object.keys(details.imageData)) out.imageDataURL[k] = toURL(details.imageData[k]); }
      } catch (e) { console.warn('[Rikugan] action.setIcon imageData conversion failed', e); }
      delete out.imageData;
      return out;
    };
    const action = guarded('action', {
      setBadgeText: call('action.setBadgeText'), getBadgeText: call('action.getBadgeText'),
      setBadgeBackgroundColor: call('action.setBadgeBackgroundColor'), getBadgeBackgroundColor: call('action.getBadgeBackgroundColor'),
      setBadgeTextColor: call('action.setBadgeTextColor'), getBadgeTextColor: call('action.getBadgeTextColor'),
      setTitle: call('action.setTitle'), getTitle: call('action.getTitle'),
      setIcon: api(async (details) => bridge('action.setIcon', { args: [await iconToData(details)] })),
      setPopup: call('action.setPopup'), getPopup: call('action.getPopup'), openPopup: call('action.openPopup'),
      enable: call('action.enable'), disable: call('action.disable'), isEnabled: call('action.isEnabled'),
      getUserSettings: api(async () => ({ isOnToolbar: true })),
      onClicked: ev('action.onClicked'), onUserSettingsChanged: ev('action.onUserSettingsChanged'),
    });
    chrome.action = action;
    chrome.browserAction = action;
    chrome.pageAction = action;

    // ---- context menus ----------------------------------------------------------------------------
    let menuSeq = 0;
    const menuCallbacks = new Map();
    const contextMenus = guarded('contextMenus', {
      ACTION_MENU_TOP_LEVEL_LIMIT: 6,
      ContextType: { ALL: 'all', PAGE: 'page', FRAME: 'frame', SELECTION: 'selection', LINK: 'link', EDITABLE: 'editable', IMAGE: 'image', VIDEO: 'video', AUDIO: 'audio', LAUNCHER: 'launcher', BROWSER_ACTION: 'browser_action', PAGE_ACTION: 'page_action', ACTION: 'action' },
      ItemType: { NORMAL: 'normal', CHECKBOX: 'checkbox', RADIO: 'radio', SEPARATOR: 'separator' },
      create: (props, cb) => {
        props = Object.assign({}, props || {});
        const id = props.id !== undefined ? String(props.id) : String(++menuSeq);
        if (typeof props.onclick === 'function') menuCallbacks.set(id, props.onclick);
        delete props.onclick;
        props.id = id;
        bridge('contextMenus.create', { args: [props] }).then(() => { if (cb) cb(); }, (e) => { if (cb) withLastError(e, () => cb()); });
        return props.id;
      },
      update: call('contextMenus.update'), remove: call('contextMenus.remove'), removeAll: call('contextMenus.removeAll'),
      onClicked: ev('contextMenus.onClicked'),
    });
    contextMenus.onClicked.addListener((info, tab) => { const f = menuCallbacks.get(String(info.menuItemId)); if (f) f(info, tab); });
    chrome.contextMenus = contextMenus;
    chrome.menus = contextMenus;

    chrome.commands = guarded('commands', { getAll: call('commands.getAll'), onCommand: ev('commands.onCommand') });
    // Font list only (system + profile-installed + imported families); per-page font settings are
    // Rikugan's own web-font feature, so the setters are explicit Unsupported stubs.
    chrome.fontSettings = guarded('fontSettings', {
      getFontList: call('fontSettings.getFontList'),
      getFont: unsupportedFn('fontSettings.getFont'), setFont: unsupportedFn('fontSettings.setFont'), clearFont: unsupportedFn('fontSettings.clearFont'),
      getDefaultFontSize: unsupportedFn('fontSettings.getDefaultFontSize'), setDefaultFontSize: unsupportedFn('fontSettings.setDefaultFontSize'),
      clearDefaultFontSize: unsupportedFn('fontSettings.clearDefaultFontSize'), getDefaultFixedFontSize: unsupportedFn('fontSettings.getDefaultFixedFontSize'),
      setDefaultFixedFontSize: unsupportedFn('fontSettings.setDefaultFixedFontSize'), clearDefaultFixedFontSize: unsupportedFn('fontSettings.clearDefaultFixedFontSize'),
      getMinimumFontSize: unsupportedFn('fontSettings.getMinimumFontSize'), setMinimumFontSize: unsupportedFn('fontSettings.setMinimumFontSize'),
      clearMinimumFontSize: unsupportedFn('fontSettings.clearMinimumFontSize'),
      onFontChanged: unsupportedEvent('fontSettings.onFontChanged'), onDefaultFontSizeChanged: unsupportedEvent('fontSettings.onDefaultFontSizeChanged'),
      onDefaultFixedFontSizeChanged: unsupportedEvent('fontSettings.onDefaultFixedFontSizeChanged'), onMinimumFontSizeChanged: unsupportedEvent('fontSettings.onMinimumFontSizeChanged'),
    });
    chrome.cookies = guarded('cookies', {
      get: call('cookies.get'), getAll: call('cookies.getAll'), set: call('cookies.set'), remove: call('cookies.remove'),
      getAllCookieStores: call('cookies.getAllCookieStores'), onChanged: ev('cookies.onChanged'),
      SameSiteStatus: { NO_RESTRICTION: 'no_restriction', LAX: 'lax', STRICT: 'strict', UNSPECIFIED: 'unspecified' },
    });
    chrome.downloads = guarded('downloads', {
      download: call('downloads.download'), search: call('downloads.search'), pause: call('downloads.pause'), resume: call('downloads.resume'),
      cancel: call('downloads.cancel'), open: call('downloads.open'), show: call('downloads.show'), erase: call('downloads.erase'),
      showDefaultFolder: api(async () => undefined), setUiOptions: api(async () => undefined),
      removeFile: call('downloads.removeFile'), getFileIcon: call('downloads.getFileIcon'),
      onCreated: ev('downloads.onCreated'), onChanged: ev('downloads.onChanged'), onErased: ev('downloads.onErased'),
    });
    chrome.notifications = guarded('notifications', {
      create: api(async (...args) => {
        let id = typeof args[0] === 'string' ? args.shift() : '';
        return bridge('notifications.create', { args: [id || uuid(), args[0] || {}] });
      }),
      update: call('notifications.update'), clear: call('notifications.clear'), getAll: call('notifications.getAll'),
      getPermissionLevel: call('notifications.getPermissionLevel'),
      onClicked: ev('notifications.onClicked'), onClosed: ev('notifications.onClosed'), onButtonClicked: ev('notifications.onButtonClicked'),
      onPermissionLevelChanged: ev('notifications.onPermissionLevelChanged'), onShowSettings: ev('notifications.onShowSettings'),
      TemplateType: { BASIC: 'basic', IMAGE: 'image', LIST: 'list', PROGRESS: 'progress' },
    });
    chrome.webNavigation = guarded('webNavigation', {
      getFrame: call('webNavigation.getFrame'), getAllFrames: call('webNavigation.getAllFrames'),
      onBeforeNavigate: ev('webNavigation.onBeforeNavigate'), onCommitted: ev('webNavigation.onCommitted'),
      onDOMContentLoaded: ev('webNavigation.onDOMContentLoaded'), onCompleted: ev('webNavigation.onCompleted'),
      onErrorOccurred: ev('webNavigation.onErrorOccurred'), onCreatedNavigationTarget: ev('webNavigation.onCreatedNavigationTarget'),
      onReferenceFragmentUpdated: unsupportedEvent('webNavigation.onReferenceFragmentUpdated'), onTabReplaced: unsupportedEvent('webNavigation.onTabReplaced'),
      onHistoryStateUpdated: ev('webNavigation.onHistoryStateUpdated'),
    });
    chrome.declarativeNetRequest = guarded('declarativeNetRequest', {
      MAX_NUMBER_OF_RULES: 30000, MAX_NUMBER_OF_DYNAMIC_RULES: 30000, MAX_NUMBER_OF_DYNAMIC_AND_SESSION_RULES: 30000,
      MAX_NUMBER_OF_SESSION_RULES: 5000, MAX_NUMBER_OF_UNSAFE_DYNAMIC_RULES: 5000, MAX_NUMBER_OF_UNSAFE_SESSION_RULES: 5000,
      MAX_NUMBER_OF_REGEX_RULES: 1000, MAX_NUMBER_OF_STATIC_RULESETS: 100, MAX_NUMBER_OF_ENABLED_STATIC_RULESETS: 50,
      GUARANTEED_MINIMUM_STATIC_RULES: 30000, DYNAMIC_RULESET_ID: '_dynamic', SESSION_RULESET_ID: '_session',
      updateDynamicRules: call('declarativeNetRequest.updateDynamicRules'), getDynamicRules: call('declarativeNetRequest.getDynamicRules'),
      updateSessionRules: call('declarativeNetRequest.updateSessionRules'), getSessionRules: call('declarativeNetRequest.getSessionRules'),
      updateEnabledRulesets: call('declarativeNetRequest.updateEnabledRulesets'), getEnabledRulesets: call('declarativeNetRequest.getEnabledRulesets'),
      updateStaticRules: unsupportedFn('declarativeNetRequest.updateStaticRules'), getDisabledRuleIds: api(async () => []),
      getAvailableStaticRuleCount: api(async () => 30000),
      isRegexSupported: call('declarativeNetRequest.isRegexSupported'),
      setExtensionActionOptions: api(async () => undefined),
      getMatchedRules: unsupportedFn('declarativeNetRequest.getMatchedRules'),
      testMatchOutcome: unsupportedFn('declarativeNetRequest.testMatchOutcome'),
      onRuleMatchedDebug: unsupportedEvent('declarativeNetRequest.onRuleMatchedDebug'),
      RuleActionType: { BLOCK: 'block', REDIRECT: 'redirect', ALLOW: 'allow', UPGRADE_SCHEME: 'upgradeScheme', MODIFY_HEADERS: 'modifyHeaders', ALLOW_ALL_REQUESTS: 'allowAllRequests' },
      ResourceType: { MAIN_FRAME: 'main_frame', SUB_FRAME: 'sub_frame', STYLESHEET: 'stylesheet', SCRIPT: 'script', IMAGE: 'image', FONT: 'font', OBJECT: 'object', XMLHTTPREQUEST: 'xmlhttprequest', PING: 'ping', CSP_REPORT: 'csp_report', MEDIA: 'media', WEBSOCKET: 'websocket', WEBTRANSPORT: 'webtransport', WEBBUNDLE: 'webbundle', OTHER: 'other' },
      DomainType: { FIRST_PARTY: 'firstParty', THIRD_PARTY: 'thirdParty' },
    });
    // ---- identity ------------------------------------------------------------------------------
    // Web auth flows (OAuth / OpenID) work; Chrome-account tokens do not exist on iOS.
    chrome.identity = guarded('identity', {
      getRedirectURL: (path) => 'https://' + cfg.extId + '.chromiumapp.org/' + String(path || '').replace(/^\//, ''),
      launchWebAuthFlow: call('identity.launchWebAuthFlow'),
      getProfileUserInfo: api(async () => ({ email: '', id: '' })),
      removeCachedAuthToken: api(async () => undefined),
      clearAllCachedAuthTokens: api(async () => undefined),
      getAuthToken: unsupportedFn('identity.getAuthToken'),
      getAccounts: unsupportedFn('identity.getAccounts'),
      onSignInChanged: ev('identity.onSignInChanged'),
      AccountStatus: { SYNC: 'SYNC', ANY: 'ANY' },
    });

    // ---- history / bookmarks / topSites / sessions / search -------------------------------------
    chrome.history = guarded('history', {
      search: call('history.search'), getVisits: call('history.getVisits'), addUrl: call('history.addUrl'),
      deleteUrl: call('history.deleteUrl'), deleteRange: call('history.deleteRange'), deleteAll: call('history.deleteAll'),
      onVisited: ev('history.onVisited'), onVisitRemoved: ev('history.onVisitRemoved'),
      TransitionType: { LINK: 'link', TYPED: 'typed', AUTO_BOOKMARK: 'auto_bookmark', AUTO_SUBFRAME: 'auto_subframe', MANUAL_SUBFRAME: 'manual_subframe', GENERATED: 'generated', AUTO_TOPLEVEL: 'auto_toplevel', FORM_SUBMIT: 'form_submit', RELOAD: 'reload', KEYWORD: 'keyword', KEYWORD_GENERATED: 'keyword_generated' },
    });
    chrome.bookmarks = guarded('bookmarks', {
      MAX_WRITE_OPERATIONS_PER_HOUR: 1000000, MAX_SUSTAINED_WRITE_OPERATIONS_PER_MINUTE: 1000000,
      get: call('bookmarks.get'), getChildren: call('bookmarks.getChildren'), getRecent: call('bookmarks.getRecent'),
      getTree: call('bookmarks.getTree'), getSubTree: call('bookmarks.getSubTree'), search: call('bookmarks.search'),
      create: call('bookmarks.create'), move: call('bookmarks.move'), update: call('bookmarks.update'),
      remove: call('bookmarks.remove'), removeTree: call('bookmarks.removeTree'),
      onCreated: ev('bookmarks.onCreated'), onRemoved: ev('bookmarks.onRemoved'), onChanged: ev('bookmarks.onChanged'),
      onMoved: ev('bookmarks.onMoved'), onChildrenReordered: ev('bookmarks.onChildrenReordered'),
      onImportBegan: ev('bookmarks.onImportBegan'), onImportEnded: ev('bookmarks.onImportEnded'),
      FolderType: { BOOKMARKS_BAR: 'bookmarks-bar', OTHER: 'other', MOBILE: 'mobile', MANAGED: 'managed' },
    });
    chrome.topSites = guarded('topSites', { get: call('topSites.get') });
    chrome.sessions = guarded('sessions', {
      MAX_SESSION_RESULTS: 25,
      getRecentlyClosed: call('sessions.getRecentlyClosed'), restore: call('sessions.restore'),
      getDevices: api(async () => []), onChanged: ev('sessions.onChanged'),
    });
    chrome.search = guarded('search', {
      query: call('search.query'),
      Disposition: { CURRENT_TAB: 'CURRENT_TAB', NEW_TAB: 'NEW_TAB', NEW_WINDOW: 'NEW_WINDOW' },
    });

    // ---- tts ------------------------------------------------------------------------------------
    chrome.tts = guarded('tts', {
      speak: api(async (utterance, options) => {
        const opts = Object.assign({}, options || {});
        let id = null;
        if (typeof opts.onEvent === 'function') { id = uuid(); ttsCallbacks.set(id, opts.onEvent); }
        delete opts.onEvent;
        await bridge('tts.speak', { args: [String(utterance), jsonable(opts), id] });
      }),
      stop: () => { bridge('tts.stop', { args: [] }).catch(() => {}); },
      pause: () => { bridge('tts.pause', { args: [] }).catch(() => {}); },
      resume: () => { bridge('tts.resume', { args: [] }).catch(() => {}); },
      isSpeaking: call('tts.isSpeaking'), getVoices: call('tts.getVoices'),
      onVoicesChanged: ev('tts.onVoicesChanged'),
      EventType: { START: 'start', END: 'end', WORD: 'word', SENTENCE: 'sentence', MARKER: 'marker', INTERRUPTED: 'interrupted', CANCELLED: 'cancelled', ERROR: 'error', PAUSE: 'pause', RESUME: 'resume' },
    });

    // ---- management -----------------------------------------------------------------------------
    chrome.management = guarded('management', {
      getSelf: call('management.getSelf'), get: call('management.get'), getAll: call('management.getAll'),
      getPermissionWarningsById: call('management.getPermissionWarningsById'),
      getPermissionWarningsByManifest: call('management.getPermissionWarningsByManifest'),
      setEnabled: call('management.setEnabled'), uninstall: call('management.uninstall'), uninstallSelf: call('management.uninstallSelf'),
      launchApp: unsupportedFn('management.launchApp'), createAppShortcut: unsupportedFn('management.createAppShortcut'),
      setLaunchType: unsupportedFn('management.setLaunchType'), generateAppForLink: unsupportedFn('management.generateAppForLink'),
      onInstalled: ev('management.onInstalled'), onUninstalled: ev('management.onUninstalled'),
      onEnabled: ev('management.onEnabled'), onDisabled: ev('management.onDisabled'),
      ExtensionType: { EXTENSION: 'extension', HOSTED_APP: 'hosted_app', PACKAGED_APP: 'packaged_app', LEGACY_PACKAGED_APP: 'legacy_packaged_app', THEME: 'theme', LOGIN_SCREEN_EXTENSION: 'login_screen_extension' },
      ExtensionInstallType: { ADMIN: 'admin', DEVELOPMENT: 'development', NORMAL: 'normal', SIDELOAD: 'sideload', OTHER: 'other' },
    });

    // ---- browsingData ---------------------------------------------------------------------------
    const removeOne = (key) => api(async (options) => bridge('browsingData.remove', { args: [options || {}, { [key]: true }] }));
    chrome.browsingData = guarded('browsingData', {
      remove: call('browsingData.remove'), settings: call('browsingData.settings'),
      removeAppcache: removeOne('appcache'), removeCache: removeOne('cache'), removeCacheStorage: removeOne('cacheStorage'),
      removeCookies: removeOne('cookies'), removeDownloads: removeOne('downloads'), removeFileSystems: removeOne('fileSystems'),
      removeHistory: removeOne('history'), removeIndexedDB: removeOne('indexedDB'), removeLocalStorage: removeOne('localStorage'),
      removeServiceWorkers: removeOne('serviceWorkers'), removeWebSQL: removeOne('webSQL'),
      removeFormData: unsupportedFn('browsingData.removeFormData'), removePasswords: unsupportedFn('browsingData.removePasswords'),
      removePluginData: unsupportedFn('browsingData.removePluginData'),
    });

    // ---- idle -----------------------------------------------------------------------------------
    chrome.idle = guarded('idle', {
      queryState: call('idle.queryState'), setDetectionInterval: (seconds) => { bridge('idle.setDetectionInterval', { args: [seconds] }).catch(() => {}); },
      getAutoLockDelay: unsupportedFn('idle.getAutoLockDelay'), onStateChanged: ev('idle.onStateChanged'),
      IdleState: { ACTIVE: 'active', IDLE: 'idle', LOCKED: 'locked' },
    });

    chrome.alarms = guarded('alarms', {
      create: api(async (...args) => { const name = typeof args[0] === 'string' ? args.shift() : ''; return bridge('alarms.create', { args: [name, args[0] || {}] }); }),
      get: call('alarms.get'), getAll: call('alarms.getAll'), clear: call('alarms.clear'), clearAll: call('alarms.clearAll'),
      onAlarm: ev('alarms.onAlarm'),
    });
  }

  // Namespaces that exist in Chrome but are not implemented: explicit stubs, never undefined crashes.
  for (const ns of cfg.unsupported || []) {
    if (!(ns in chrome) && (cfg.ctx !== 'content')) chrome[ns] = unsupportedNamespace(ns);
  }
  const chromeProxy = cfg.ctx === 'content' ? chrome : guarded('', chrome);

  // ---- Native → JS entry points --------------------------------------------------------------------
  const internal = {
    extId: cfg.extId,
    dispatch(name, args) {
      if (name === 'tts._event') {
        const [id, event] = args || [];
        const cb = ttsCallbacks.get(id);
        if (!cb) return false;
        if (['end', 'interrupted', 'cancelled', 'error'].includes(event && event.type)) ttsCallbacks.delete(id);
        try { cb(event); } catch (e) { console.error('[tts.onEvent]', e); }
        return true;
      }
      const e = events.get(name);
      if (name.startsWith('storage.') && name.endsWith('.onChanged') && Array.isArray(args)) {
        const changes = {};
        for (const k of Object.keys(args[0] || {})) {
          const c = args[0][k];
          changes[k] = {};
          if (c.oldValue !== undefined && c.oldValue !== null) changes[k].oldValue = JSON.parse(c.oldValue);
          if (c.newValue !== undefined && c.newValue !== null) changes[k].newValue = JSON.parse(c.newValue);
        }
        const area = name.split('.')[1];
        if (e) e._dispatch([changes]);
        const all = events.get('storage.onChanged');
        if (all) all._dispatch([changes, area]);
        return true;
      }
      if (!e) return false;
      if (name === 'runtime.onInstalled' || name === 'runtime.onStartup') {
        if (cfg.ctx === 'background' && name === 'runtime.onInstalled') internal.installed = true;
      }
      e._dispatch(args || []);
      return true;
    },
    deliverMessage,
    openPort(portId, name, sender) {
      if (!onConnect.hasListeners()) return false;
      const port = new Port(portId, name, sender);
      onConnect._dispatch([port]);
      return true;
    },
    portEvent(portId, type, message) {
      const port = portsById.get(portId);
      if (!port) return false;
      if (type === 'message') port.onMessage._dispatch([message, port]);
      else if (type === 'disconnect') { port._connected = false; portsById.delete(portId); port.onDisconnect._dispatch([port]); }
      return true;
    },
    hasMessageListeners() { return onMessage.hasListeners(); },
  };
  Object.defineProperty(g, '__rikuganChrome', { value: internal, configurable: false, enumerable: false, writable: false });
  try { Object.defineProperty(g, 'chrome', { value: chromeProxy, configurable: true, writable: true, enumerable: true }); } catch (_) { g.chrome = chromeProxy; }
  if (!g.browser || !g.browser.runtime) {
    try { Object.defineProperty(g, 'browser', { value: chromeProxy, configurable: true, writable: true }); } catch (_) {}
  }

  if (cfg.ctx === 'background') {
    // Service-worker style globals for MV3 background scripts running in the hidden background page.
    const noop = () => Promise.resolve();
    g.registration = g.registration || { scope: cfg.baseURL, active: { state: 'activated' }, unregister: noop, update: noop, showNotification: (t, o) => chromeProxy.notifications.create({ title: t, message: (o && o.body) || '', type: 'basic' }) };
    g.skipWaiting = g.skipWaiting || noop;
    g.clients = g.clients || { claim: noop, matchAll: () => Promise.resolve([]), get: () => Promise.resolve(undefined), openWindow: (url) => chromeProxy.tabs.create({ url }) };
    g.importScripts = function (...urls) {
      for (const u of urls) {
        const url = new URL(u, location.href).href;
        const xhr = new XMLHttpRequest();
        xhr.open('GET', url, false);
        xhr.send(null);
        if (xhr.status && xhr.status !== 200) throw new Error('importScripts failed: ' + url);
        (0, eval)(xhr.responseText + '\n//# sourceURL=' + url);
      }
    };
  }
  // Runtime errors of extension code are reported to the native side (Diagnostics / compatibility reports).
  let reportedErrors = 0;
  const reportError = (message) => {
    if (reportedErrors++ > 20) return;
    bridge('runtime._reportError', { message: String(message).slice(0, 300) }).catch(() => {});
  };
  if (typeof addEventListener === 'function') {
    // Only errors thrown by this extension's own code (content scripts carry an extension sourceURL);
    // page errors seen through the shared DOM are ignored.
    addEventListener('error', (e) => {
      if (!e.filename || !String(e.filename).startsWith(cfg.baseURL)) return;
      reportError((e.message || 'Error') + ' @ ' + String(e.filename).slice(cfg.baseURL.length) + ':' + e.lineno);
    });
    if (cfg.ctx !== 'content') addEventListener('unhandledrejection', (e) => reportError('Unhandled rejection: ' + (e.reason && e.reason.message || e.reason)));
  }

  if (cfg.ctx !== 'content') {
    const signalReady = () => bridge('runtime._ready', { ctx: cfg.ctx, url: String(location.href) }).catch(() => {});
    if (document.readyState === 'complete') setTimeout(signalReady, 0);
    else addEventListener('load', () => setTimeout(signalReady, 0), { once: true });
  } else {
    const isTopFrame = (() => { try { return top === self; } catch (_) { return false; } })();
    const frameToken = contentFrameToken;
    bridge('runtime._ready', { ctx: 'content', url: String(location.href), top: isTopFrame, frameToken }).catch(() => {});
    if (!isTopFrame && typeof addEventListener === 'function') {
      addEventListener('pagehide', () => { bridge('runtime._frameGone', { frameToken }).catch(() => {}); });
    }
  }
})(/*__RK_CHROME_CONFIG__*/null);
