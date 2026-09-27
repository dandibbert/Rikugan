// Rikugan userscript runtime. One copy wraps every installed userscript.
// Swift replaces the CONFIG placeholder with JSON and the BODY placeholder with @require code + source.
// Intentionally NOT strict mode: userscripts frequently rely on sloppy-mode semantics.
(function () {
  const __RK = /*__RK_CONFIG__*/null;
  if (!__RK) return;
  const isTop = (() => { try { return window.top === window; } catch (_) { return false; } })();
  if (__RK.frameMode === 'main' && !isTop) return;
  if (__RK.frameMode === 'sub') {
    if (isTop) return;
    const href = String(location.href).split('#')[0];
    const inc = __RK.include.map(r => new RegExp(r[0], r[1]));
    const exc = __RK.exclude.map(r => new RegExp(r[0], r[1]));
    if (!inc.some(r => r.test(href)) || exc.some(r => r.test(href))) return;
  }
  const registryKey = '__rikuganUS_' + __RK.id.replace(/-/g, '');
  if (window[registryKey]) return; // already injected in this world/frame
  Object.defineProperty(window, registryKey, { value: true, enumerable: false });

  // Security boundary: the native GM bridge is only used from the script's own isolated
  // WKContentWorld, where page JavaScript cannot see or call it. A page-world script is plain page
  // JavaScript — it gets no bridge, no credentials and no stored values; privileged GM APIs throw.
  const privileged = __RK.world !== 'page';
  const handler = privileged && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[__RK.handler];
  const postRaw = handler ? handler.postMessage.bind(handler) : null;
  const pageWorldError = (name) => new Error('Rikugan: ' + name + ' is not available to page-world userscripts (the page could forge any privileged call made from there). Use @inject-into content or remove @inject-into page.');
  const post = (op, args) => {
    if (!privileged) return Promise.reject(pageWorldError('GM ' + op));
    if (!postRaw) return Promise.reject(new Error('Rikugan bridge unavailable'));
    return postRaw({ ch: 'gm', sid: __RK.id, op, args: args === undefined ? null : args });
  };
  const logPrefix = '[' + __RK.name + ']';
  const unsupported = (name) => function () {
    const error = new Error('Unsupported API: ' + name + ' is not implemented by Rikugan');
    console.warn(logPrefix, error.message);
    throw error;
  };
  const hasGrant = (...names) => __RK.grants.some(g => names.includes(g));
  const grantAll = __RK.grants.length === 0 || (__RK.grants.length === 1 && __RK.grants[0] === 'none');

  // ---- Values -------------------------------------------------------------------------------
  const values = Object.create(null);
  const decodeValue = (text) => { try { return JSON.parse(text); } catch (_) { return undefined; } };
  for (const key of Object.keys(__RK.values || {})) values[key] = __RK.values[key];
  const listeners = new Map();
  let listenerSeq = 0;
  const fireChange = (key, oldText, newText, remote) => {
    for (const [, l] of listeners) {
      if (l.key !== key) continue;
      try { l.cb(key, oldText === undefined ? undefined : decodeValue(oldText), newText === undefined ? undefined : decodeValue(newText), remote); }
      catch (e) { console.error(logPrefix, e); }
    }
  };
  const GM_getValue = (key, defaultValue) => {
    key = String(key);
    if (!(key in values)) return defaultValue;
    const v = decodeValue(values[key]);
    return v === undefined ? defaultValue : v;
  };
  const GM_setValue = (key, value) => {
    key = String(key);
    let text;
    try { text = JSON.stringify(value === undefined ? null : value); } catch (e) { throw new Error('GM_setValue: value is not serialisable: ' + e.message); }
    const old = values[key];
    values[key] = text;
    post('setValue', { key, value: text }).catch(e => console.error(logPrefix, 'GM_setValue failed', e));
    if (old !== text) fireChange(key, old, text, false);
  };
  const GM_deleteValue = (key) => {
    key = String(key);
    const old = values[key];
    delete values[key];
    post('deleteValue', { key }).catch(e => console.error(logPrefix, e));
    if (old !== undefined) fireChange(key, old, undefined, false);
  };
  const GM_listValues = () => Object.keys(values);
  const GM_getValues = (keys) => {
    const out = {};
    if (Array.isArray(keys)) keys.forEach(k => { if (k in values) out[k] = decodeValue(values[k]); });
    else if (keys && typeof keys === 'object') Object.keys(keys).forEach(k => { out[k] = k in values ? decodeValue(values[k]) : keys[k]; });
    return out;
  };
  const GM_setValues = (obj) => { Object.keys(obj || {}).forEach(k => GM_setValue(k, obj[k])); };
  const GM_deleteValues = (keys) => { (keys || []).forEach(k => GM_deleteValue(k)); };
  const GM_addValueChangeListener = (key, cb) => { const id = ++listenerSeq; listeners.set(id, { key: String(key), cb }); return id; };
  const GM_removeValueChangeListener = (id) => { listeners.delete(id); };

  // Refresh the cache with the authoritative native store (values may have changed since injection).
  const ready = post('getAll', null).then(all => {
    if (!all || typeof all !== 'object') return;
    for (const key of Object.keys(values)) if (!(key in all)) delete values[key];
    for (const key of Object.keys(all)) values[key] = all[key];
  }).catch(() => {});

  // ---- Styles / DOM -------------------------------------------------------------------------
  const whenRoot = (fn) => {
    if (document.documentElement) return fn();
    const obs = new MutationObserver(() => { if (document.documentElement) { obs.disconnect(); fn(); } });
    obs.observe(document, { childList: true });
  };
  const GM_addStyle = (css) => {
    css = String(css);
    const style = document.createElement('style');
    style.textContent = css;
    style.setAttribute('data-rikugan-userscript', __RK.name);
    whenRoot(() => {
      (document.head || document.documentElement).appendChild(style);
      try {
        const blocked = !style.sheet || (style.sheet.cssRules.length === 0 && css.trim().length > 0);
        if (blocked && 'adoptedStyleSheets' in document) {
          const sheet = new CSSStyleSheet();
          sheet.replaceSync(css);
          document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
        }
      } catch (_) {}
    });
    return style;
  };
  const GM_addElement = (parent, tag, attributes) => {
    if (typeof parent === 'string') { attributes = tag; tag = parent; parent = null; }
    const el = document.createElement(tag);
    for (const [k, v] of Object.entries(attributes || {})) {
      if (k === 'textContent') el.textContent = v; else if (k === 'innerHTML') el.innerHTML = v; else el.setAttribute(k, v);
    }
    const target = parent || (['script', 'style', 'link', 'meta'].includes(String(tag).toLowerCase()) ? (document.head || document.documentElement) : (document.body || document.documentElement));
    target.appendChild(el);
    return el;
  };

  // ---- Resources ----------------------------------------------------------------------------
  const b64ToText = (b64) => {
    const bin = atob(b64);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return new TextDecoder().decode(bytes);
  };
  const GM_getResourceText = (name) => {
    const r = (__RK.resources || {})[name];
    if (!r) { console.warn(logPrefix, 'Unknown @resource', name); return null; }
    return b64ToText(r.data);
  };
  const GM_getResourceURL = (name, isBlobUrl) => {
    const r = (__RK.resources || {})[name];
    if (!r) { console.warn(logPrefix, 'Unknown @resource', name); return null; }
    return 'data:' + (r.mime || 'application/octet-stream') + ';base64,' + r.data;
  };

  // ---- Clipboard / tabs / notifications ------------------------------------------------------
  const GM_setClipboard = (data, info, cb) => {
    const type = typeof info === 'string' ? info : (info && (info.type || info.mimetype)) || 'text';
    const p = post('clipboard', { text: String(data), type });
    p.then(() => { if (typeof cb === 'function') cb(); }).catch(e => console.error(logPrefix, e));
    return p;
  };
  const GM_openInTab = (url, options) => {
    const background = options === true || (options && (options.active === false || options.loadInBackground === true));
    const handle = { closed: false, onclose: null, close() { if (handle._id) post('closeTab', { tabId: handle._id }); handle.closed = true; } };
    handle._promise = post('openInTab', { url: new URL(String(url), location.href).href, background: !!background, insert: !!(options && options.insert) })
      .then(id => { handle._id = id; return handle; });
    return handle;
  };
  const GM_notification = (details, title, image, onclick) => {
    if (typeof details === 'string') details = { text: details, title, image, onclick };
    details = details || {};
    const p = post('notification', { text: String(details.text || ''), title: String(details.title || __RK.name), timeout: details.timeout || 0 });
    p.then(r => {
      if (r === 'clicked' && typeof details.onclick === 'function') details.onclick();
      if (typeof details.ondone === 'function') details.ondone(r === 'clicked');
    }).catch(() => {});
    return p;
  };
  const GM_download = (details, name) => {
    if (typeof details === 'string') details = { url: details, name };
    details = details || {};
    const p = post('download', { url: new URL(String(details.url), location.href).href, name: details.name || '', headers: details.headers || {} });
    p.then(r => { if (typeof details.onload === 'function') details.onload(r); })
      .catch(e => { if (typeof details.onerror === 'function') details.onerror({ error: 'download_failed', details: String(e) }); });
    return { abort() {} };
  };
  const tabState = { value: null };
  const GM_getTab = (cb) => { const p = post('getTab', null).then(v => { tabState.value = v || {}; if (cb) cb(tabState.value); return tabState.value; }); return p; };
  const GM_saveTab = (tab) => post('saveTab', { value: tab || {} });
  const GM_getTabs = (cb) => post('getTabs', null).then(v => { if (cb) cb(v || {}); return v || {}; });

  // ---- Menu commands ------------------------------------------------------------------------
  const menuCallbacks = new Map();
  let menuSeq = 0;
  const GM_registerMenuCommand = (name, fn, options) => {
    const id = (options && typeof options === 'object' && options.id) ? String(options.id) : String(++menuSeq);
    menuCallbacks.set(id, fn);
    const title = (options && typeof options === 'object' && options.title) || '';
    post('menuRegister', { id, name: String(name), title: String(title) }).catch(() => {});
    return id;
  };
  const GM_unregisterMenuCommand = (id) => { menuCallbacks.delete(String(id)); post('menuUnregister', { id: String(id) }).catch(() => {}); };

  // ---- XHR -----------------------------------------------------------------------------------
  let xhrSeq = 0;
  const bytesToB64 = (bytes) => {
    let bin = '';
    const chunk = 0x8000;
    for (let i = 0; i < bytes.length; i += chunk) bin += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
    return btoa(bin);
  };
  const serializeBody = async (data) => {
    if (data === undefined || data === null) return { body: null };
    if (typeof data === 'string') return { body: data };
    if (typeof URLSearchParams !== 'undefined' && data instanceof URLSearchParams) return { body: data.toString(), contentType: 'application/x-www-form-urlencoded;charset=UTF-8' };
    if (data instanceof ArrayBuffer) return { base64: bytesToB64(new Uint8Array(data)) };
    if (ArrayBuffer.isView(data)) return { base64: bytesToB64(new Uint8Array(data.buffer, data.byteOffset, data.byteLength)) };
    if (typeof Blob !== 'undefined' && data instanceof Blob) return { base64: bytesToB64(new Uint8Array(await data.arrayBuffer())), contentType: data.type || undefined };
    if (typeof FormData !== 'undefined' && data instanceof FormData) {
      const boundary = '----RikuganFormBoundary' + Math.random().toString(16).slice(2);
      const encoder = new TextEncoder();
      const parts = [];
      for (const [key, value] of data.entries()) {
        let head = '--' + boundary + '\r\nContent-Disposition: form-data; name="' + key + '"';
        if (typeof value === 'string') {
          parts.push(encoder.encode(head + '\r\n\r\n' + value + '\r\n'));
        } else {
          head += '; filename="' + (value.name || 'blob') + '"\r\nContent-Type: ' + (value.type || 'application/octet-stream') + '\r\n\r\n';
          parts.push(encoder.encode(head), new Uint8Array(await value.arrayBuffer()), encoder.encode('\r\n'));
        }
      }
      parts.push(encoder.encode('--' + boundary + '--\r\n'));
      const total = parts.reduce((n, p) => n + p.length, 0);
      const out = new Uint8Array(total);
      let offset = 0;
      for (const p of parts) { out.set(p, offset); offset += p.length; }
      return { base64: bytesToB64(out), contentType: 'multipart/form-data; boundary=' + boundary };
    }
    if (typeof data === 'object') return { body: JSON.stringify(data) };
    return { body: String(data) };
  };
  const buildResponse = (details, raw) => {
    const response = {
      readyState: 4, status: raw.status, statusText: raw.statusText || '', finalUrl: raw.finalUrl, responseHeaders: raw.responseHeaders || '',
      context: details.context, responseText: undefined, response: undefined, responseXML: undefined,
      lengthComputable: true, loaded: raw.size || 0, total: raw.size || 0,
    };
    const type = String(details.responseType || '').toLowerCase();
    let bytes = null;
    const getBytes = () => {
      if (bytes) return bytes;
      const bin = atob(raw.base64 || '');
      bytes = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
      return bytes;
    };
    let textCache;
    const getText = () => {
      if (textCache !== undefined) return textCache;
      if (typeof raw.text === 'string') return (textCache = raw.text);
      const charset = /charset=([^;]+)/i.exec(raw.contentType || details.overrideMimeType || '');
      try { textCache = new TextDecoder(charset ? charset[1].trim() : 'utf-8').decode(getBytes()); }
      catch (_) { textCache = new TextDecoder().decode(getBytes()); }
      return textCache;
    };
    Object.defineProperty(response, 'responseText', { get: getText, enumerable: true });
    Object.defineProperty(response, 'responseXML', { enumerable: true, get() {
      try { return new DOMParser().parseFromString(getText(), /xml/.test(raw.contentType || '') ? 'text/xml' : 'text/html'); } catch (_) { return null; }
    } });
    Object.defineProperty(response, 'response', { enumerable: true, get() {
      switch (type) {
        case 'json': try { return JSON.parse(getText()); } catch (_) { return null; }
        case 'arraybuffer': return getBytes().buffer.slice(0);
        case 'blob': return new Blob([getBytes()], { type: raw.contentType || 'application/octet-stream' });
        case 'document': return response.responseXML;
        case 'stream': return new Blob([getBytes()]).stream();
        default: return getText();
      }
    } });
    return response;
  };
  const xhrCore = (details) => {
    details = details || {};
    const id = __RK.id + ':' + (++xhrSeq);
    let aborted = false, done = false;
    const call = (name, arg) => { try { if (typeof details[name] === 'function') details[name](arg); } catch (e) { console.error(logPrefix, e); } };
    const promise = (async () => {
      const url = new URL(String(details.url), location.href).href;
      const body = await serializeBody(details.data);
      const headers = Object.assign({}, details.headers || {});
      if (body.contentType && !Object.keys(headers).some(k => k.toLowerCase() === 'content-type')) headers['Content-Type'] = body.contentType;
      call('onloadstart', { readyState: 1, status: 0, finalUrl: url, context: details.context });
      const raw = await post('xhr', {
        id, url, method: String(details.method || 'GET').toUpperCase(), headers, body: body.body === undefined ? null : body.body,
        bodyBase64: body.base64 || null, timeout: details.timeout || 0, anonymous: !!details.anonymous,
        user: details.user || null, password: details.password || null, overrideMimeType: details.overrideMimeType || null,
        redirect: details.redirect || 'follow', binary: ['arraybuffer', 'blob', 'stream'].includes(String(details.responseType || '').toLowerCase()),
      });
      done = true;
      if (aborted) return null;
      if (raw && raw.error) {
        const err = { error: raw.error, readyState: 4, status: 0, statusText: raw.error, finalUrl: url, context: details.context };
        if (raw.error === 'timeout') call('ontimeout', err); else call('onerror', err);
        call('onloadend', err);
        throw Object.assign(new Error(raw.error), err);
      }
      const response = buildResponse(details, raw);
      call('onreadystatechange', response);
      call('onprogress', response);
      call('onload', response);
      call('onloadend', response);
      return response;
    })();
    promise.catch(e => { if (!done && !aborted) call('onerror', { error: String(e && e.message || e), readyState: 4, status: 0 }); });
    const abort = () => {
      if (done || aborted) return;
      aborted = true;
      post('xhrAbort', { id }).catch(() => {});
      call('onabort', { readyState: 4, status: 0 });
    };
    return { promise, abort };
  };
  const GM_xmlhttpRequest = (details) => { const r = xhrCore(details); r.promise.catch(() => {}); return { abort: r.abort }; };
  const GMxhr = (details) => { const r = xhrCore(details); const p = r.promise; p.abort = r.abort; return p; };

  // ---- Info -------------------------------------------------------------------------------------
  const GM_info = Object.freeze({
    script: Object.freeze(Object.assign({}, __RK.meta, { grant: __RK.grants, 'run-at': __RK.runAt, runAt: __RK.runAt })),
    scriptMetaStr: __RK.metaStr,
    scriptHandler: 'Rikugan',
    version: __RK.appVersion,
    scriptWillUpdate: !!__RK.meta.updateURL,
    injectInto: __RK.world,
    uuid: __RK.id,
    isIncognito: !!__RK.incognito,
    platform: { os: 'ios', arch: 'arm', browserName: 'Rikugan', browserVersion: __RK.appVersion },
    userAgent: navigator.userAgent,
    downloadMode: 'native',
  });
  const GM_log = (...args) => console.log(logPrefix, ...args);

  // ---- window.onurlchange ---------------------------------------------------------------------
  if (hasGrant('window.onurlchange')) {
    let last = location.href;
    const check = () => {
      if (location.href === last) return;
      last = location.href;
      const ev = new CustomEvent('urlchange', { detail: { url: last } });
      ev.url = last;
      try { if (typeof window.onurlchange === 'function') window.onurlchange({ url: last }); } catch (e) { console.error(e); }
      window.dispatchEvent(ev);
    };
    window.addEventListener('popstate', check);
    window.addEventListener('hashchange', check);
    setInterval(check, 400);
    if (window.onurlchange === undefined) window.onurlchange = null;
  }
  const closeWindow = () => post('closeTab', null);
  const focusWindow = () => post('focusTab', null);

  // ---- Native → script dispatch (isolated world only; the world itself is the boundary) ------
  if (privileged) Object.defineProperty(window, '__rikuganGM_' + __RK.id.replace(/-/g, ''), {
    enumerable: false,
    value: (event) => {
      if (!event) return;
      if (event.type === 'menu') {
        const fn = menuCallbacks.get(String(event.id));
        if (fn) try { fn(event.mouseEvent || new MouseEvent('click')); } catch (e) { console.error(logPrefix, e); }
      } else if (event.type === 'valueChanged') {
        const old = values[event.key];
        if (event.value === null || event.value === undefined) delete values[event.key]; else values[event.key] = event.value;
        if (old !== event.value) fireChange(event.key, old, event.value === null ? undefined : event.value, true);
      }
    },
  });

  // ---- GM.* (promise API) --------------------------------------------------------------------
  const GM = {
    info: GM_info,
    log: GM_log,
    getValue: async (k, d) => { await ready; return GM_getValue(k, d); },
    setValue: async (k, v) => GM_setValue(k, v),
    deleteValue: async (k) => GM_deleteValue(k),
    listValues: async () => { await ready; return GM_listValues(); },
    getValues: async (k) => { await ready; return GM_getValues(k); },
    setValues: async (o) => GM_setValues(o),
    deleteValues: async (k) => GM_deleteValues(k),
    addValueChangeListener: async (k, cb) => GM_addValueChangeListener(k, cb),
    removeValueChangeListener: async (id) => GM_removeValueChangeListener(id),
    addStyle: async (css) => GM_addStyle(css),
    addElement: async (...a) => GM_addElement(...a),
    setClipboard: (d, i) => GM_setClipboard(d, i),
    openInTab: (u, o) => GM_openInTab(u, o),
    notification: (d, t, i, c) => GM_notification(d, t, i, c),
    download: (d, n) => new Promise((resolve, reject) => {
      const details = typeof d === 'string' ? { url: d, name: n } : Object.assign({}, d);
      const onload = details.onload, onerror = details.onerror;
      details.onload = (r) => { if (onload) onload(r); resolve(r); };
      details.onerror = (e) => { if (onerror) onerror(e); reject(e); };
      GM_download(details);
    }),
    xmlHttpRequest: GMxhr,
    getResourceText: async (n) => GM_getResourceText(n),
    getResourceUrl: async (n) => GM_getResourceURL(n),
    registerMenuCommand: async (n, f, o) => GM_registerMenuCommand(n, f, o),
    unregisterMenuCommand: async (id) => GM_unregisterMenuCommand(id),
    getTab: () => GM_getTab(),
    saveTab: (t) => GM_saveTab(t),
    getTabs: () => GM_getTabs(),
    cookie: {
      list: () => Promise.reject(new Error('Unsupported API: GM.cookie')),
      set: () => Promise.reject(new Error('Unsupported API: GM.cookie')),
      delete: () => Promise.reject(new Error('Unsupported API: GM.cookie')),
    },
  };
  GM.xmlhttpRequest = GMxhr;
  GM.getResourceURL = GM.getResourceUrl;
  Object.freeze(GM);

  const GM_cookie = Object.assign(unsupported('GM_cookie'), { list: unsupported('GM_cookie.list'), set: unsupported('GM_cookie.set'), delete: unsupported('GM_cookie.delete') });
  const GM_webRequest = unsupported('GM_webRequest');
  const GM_audio = { setMute: unsupported('GM_audio.setMute'), getState: unsupported('GM_audio.getState') };
  const unsafeWindow = window;

  // Page-world scripts see explicit stubs for every privileged API (shadowing the implementations
  // above). The body sits in its own inner function so it may still declare its own polyfills.
  const denied = (name) => function () { throw pageWorldError(name); };
  const pageGM = Object.freeze({
    info: GM_info, log: GM_log,
    addStyle: async (css) => GM_addStyle(css), addElement: async (...a) => GM_addElement(...a),
    getResourceText: async (n) => GM_getResourceText(n), getResourceUrl: async (n) => GM_getResourceURL(n),
    getValue: () => Promise.reject(pageWorldError('GM.getValue')), setValue: () => Promise.reject(pageWorldError('GM.setValue')),
    deleteValue: () => Promise.reject(pageWorldError('GM.deleteValue')), listValues: () => Promise.reject(pageWorldError('GM.listValues')),
    getValues: () => Promise.reject(pageWorldError('GM.getValues')), setValues: () => Promise.reject(pageWorldError('GM.setValues')),
    deleteValues: () => Promise.reject(pageWorldError('GM.deleteValues')),
    xmlHttpRequest: denied('GM.xmlHttpRequest'), xmlhttpRequest: denied('GM.xmlhttpRequest'),
    setClipboard: () => Promise.reject(pageWorldError('GM.setClipboard')), openInTab: denied('GM.openInTab'),
    notification: () => Promise.reject(pageWorldError('GM.notification')), download: () => Promise.reject(pageWorldError('GM.download')),
    registerMenuCommand: () => Promise.reject(pageWorldError('GM.registerMenuCommand')),
    unregisterMenuCommand: () => Promise.reject(pageWorldError('GM.unregisterMenuCommand')),
    getTab: () => Promise.reject(pageWorldError('GM.getTab')), saveTab: () => Promise.reject(pageWorldError('GM.saveTab')),
    getTabs: () => Promise.reject(pageWorldError('GM.getTabs')),
    addValueChangeListener: () => Promise.reject(pageWorldError('GM.addValueChangeListener')),
    removeValueChangeListener: () => Promise.reject(pageWorldError('GM.removeValueChangeListener')),
  });
  const scope = privileged ? [
    GM_getValue, GM_setValue, GM_deleteValue, GM_listValues, GM_getValues, GM_setValues, GM_deleteValues,
    GM_addValueChangeListener, GM_removeValueChangeListener, GM_setClipboard, GM_openInTab, GM_notification, GM_download,
    GM_getTab, GM_saveTab, GM_getTabs, GM_registerMenuCommand, GM_unregisterMenuCommand, GM_xmlhttpRequest, GM,
  ] : [
    denied('GM_getValue'), denied('GM_setValue'), denied('GM_deleteValue'), denied('GM_listValues'), denied('GM_getValues'),
    denied('GM_setValues'), denied('GM_deleteValues'), denied('GM_addValueChangeListener'), denied('GM_removeValueChangeListener'),
    denied('GM_setClipboard'), denied('GM_openInTab'), denied('GM_notification'), denied('GM_download'),
    denied('GM_getTab'), denied('GM_saveTab'), denied('GM_getTabs'), denied('GM_registerMenuCommand'),
    denied('GM_unregisterMenuCommand'), denied('GM_xmlhttpRequest'), pageGM,
  ];

  const __rk_run = function () {
    try {
      (function (GM_getValue, GM_setValue, GM_deleteValue, GM_listValues, GM_getValues, GM_setValues, GM_deleteValues,
                 GM_addValueChangeListener, GM_removeValueChangeListener, GM_setClipboard, GM_openInTab, GM_notification, GM_download,
                 GM_getTab, GM_saveTab, GM_getTabs, GM_registerMenuCommand, GM_unregisterMenuCommand, GM_xmlhttpRequest, GM) {
        return (function () {
        /*__RK_BODY__*/
        }).call(this);
      }).apply(window, scope);
    } catch (e) {
      console.error(logPrefix, e);
      post('error', { message: String(e && e.message || e), stack: String(e && e.stack || '') }).catch(() => {});
    }
  };

  const start = () => {
    switch (__RK.runAt) {
      case 'document-start': __rk_run(); break;
      case 'document-body':
        if (document.body) __rk_run();
        else {
          const obs = new MutationObserver(() => { if (document.body) { obs.disconnect(); __rk_run(); } });
          obs.observe(document.documentElement || document, { childList: true, subtree: true });
        }
        break;
      case 'document-end': __rk_run(); break;
      default:
        if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => setTimeout(__rk_run, 0), { once: true });
        else setTimeout(__rk_run, 0);
    }
  };
  if (privileged) post('injected', { url: location.href, top: isTop }).catch(() => {});
  start();
  void grantAll; void GM_cookie; void GM_webRequest; void GM_audio; void unsafeWindow; void closeWindow; void focusWindow;
})();
