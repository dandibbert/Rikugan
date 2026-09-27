(() => {
  'use strict';
  const config = /*__CONFIG__*/;
  const glob = (pattern, value) => {
    try {
      if (pattern.startsWith('/') && pattern.endsWith('/') && pattern.length > 2) return new RegExp(pattern.slice(1, -1)).test(value);
      return new RegExp('^' + pattern.split('*').map(s => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('.*') + '$').test(value);
    } catch (_) { return false; }
  };
  const match = (pattern, raw) => {
    try {
      const url = new URL(raw);
      if (!['http:', 'https:'].includes(url.protocol)) return false;
      if (pattern === '<all_urls>') return true;
      const parts = pattern.match(/^(\*|https?):\/\/([^/]+)(\/.*)$/);
      if (!parts || (parts[1] !== '*' && parts[1] + ':' !== url.protocol)) return false;
      const h = parts[2].toLowerCase();
      const hostOK = h === '*' || h === url.hostname.toLowerCase() || h === url.host.toLowerCase() ||
        (h.startsWith('*.') && (url.hostname === h.slice(2) || url.hostname.endsWith(h.slice(1))));
      return hostOK && glob(parts[3], url.pathname + url.search);
    } catch (_) { return false; }
  };
  const siteEnabled = href => {
    const host = new URL(href).hostname.toLowerCase();
    const rule = (config.siteRules || []).find(r => host === r.host || host.endsWith('.' + r.host));
    return !rule || rule.enabled !== false;
  };
  const matched = href => siteEnabled(href) && ['http:', 'https:'].includes(new URL(href).protocol)
    && (config.matches.some(p => match(p, href)) || config.includes.some(p => glob(p, href)))
    && !config.excludes.some(p => glob(p, href)) && !config.excludeMatches.some(p => match(p, href));
  const allowed = name => config.grants.includes('GM.' + name) || config.grants.includes('GM_' + (name === 'xmlHttpRequest' ? 'xmlhttpRequest' : name));
  const clientID = config.id + '-' + (globalThis.crypto?.randomUUID?.() || Math.random().toString(36).slice(2) + Date.now());
  const call = (operation, args = {}) => window.webkit.messageHandlers[config.handler].postMessage({operation, args, client: clientID});
  const tagOf = value => Object.prototype.toString.call(value);
  const bytesToBase64 = bytes => {
    let binary = '';
    for (let offset = 0; offset < bytes.length; offset += 32768) binary += String.fromCharCode(...bytes.subarray(offset, offset + 32768));
    return btoa(binary);
  };
  const base64ToBytes = text => Uint8Array.from(atob(text), character => character.charCodeAt(0));
  const encodeStorageNode = (value, seen) => {
    if (value === undefined) return {$t: 'undefined'};
    if (value === null || typeof value === 'string' || typeof value === 'boolean') return value;
    if (typeof value === 'number') {
      if (Number.isNaN(value)) return {$t: 'number', v: 'nan'};
      if (value === Infinity) return {$t: 'number', v: 'infinity'};
      if (value === -Infinity) return {$t: 'number', v: '-infinity'};
      if (Object.is(value, -0)) return {$t: 'number', v: '-0'};
      return value;
    }
    if (typeof value === 'bigint') return {$t: 'bigint', v: String(value)};
    if (typeof value === 'function' || typeof value === 'symbol') throw new TypeError('GM storage cannot serialize ' + typeof value);
    if (seen.has(value)) throw new TypeError('GM storage cannot serialize cyclic values');
    seen.add(value);
    try {
      const kind = tagOf(value);
      if (kind === '[object Date]') return {$t: 'date', v: Number.isNaN(value.getTime()) ? null : value.toISOString()};
      if (kind === '[object RegExp]') return {$t: 'regexp', s: value.source, f: value.flags};
      if (kind === '[object Map]') return {$t: 'map', v: Array.from(value, ([key, item]) => [encodeStorageNode(key, seen), encodeStorageNode(item, seen)])};
      if (kind === '[object Set]') return {$t: 'set', v: Array.from(value, item => encodeStorageNode(item, seen))};
      if (kind === '[object ArrayBuffer]') return {$t: 'arraybuffer', v: bytesToBase64(new Uint8Array(value))};
      if (/^\[object (?:Uint|Int|Float|BigInt|BigUint)(?:8|16|32|64)?Array\]$/.test(kind) || kind === '[object Uint8ClampedArray]') {
        return {$t: 'typedarray', n: kind.slice(8, -1), v: bytesToBase64(new Uint8Array(value.buffer, value.byteOffset, value.byteLength))};
      }
      if (Array.isArray(value)) return {$t: 'array', v: value.map(item => encodeStorageNode(item, seen))};
      if (kind === '[object Object]') return {$t: 'object', v: Object.keys(value).map(key => [key, encodeStorageNode(value[key], seen)])};
      throw new TypeError('Unsupported GM storage value: ' + kind);
    } finally { seen.delete(value); }
  };
  const encodeStored = value => ({__rikugan_storage_codec__: 'v1', value: encodeStorageNode(value, new Set())});
  const decodeStorageNode = node => {
    if (!node || typeof node !== 'object' || !node.$t) return node;
    switch (node.$t) {
      case 'undefined': return undefined;
      case 'number': return node.v === 'nan' ? NaN : node.v === 'infinity' ? Infinity : node.v === '-infinity' ? -Infinity : -0;
      case 'bigint': return typeof BigInt === 'function' ? BigInt(node.v) : node.v;
      case 'date': return node.v === null ? new Date(NaN) : new Date(node.v);
      case 'regexp': return new RegExp(node.s, node.f || '');
      case 'map': return new Map((node.v || []).map(([key, value]) => [decodeStorageNode(key), decodeStorageNode(value)]));
      case 'set': return new Set((node.v || []).map(decodeStorageNode));
      case 'arraybuffer': return base64ToBytes(node.v || '').buffer;
      case 'typedarray': {
        const bytes = base64ToBytes(node.v || '');
        const constructors = {Uint8Array, Uint8ClampedArray, Uint16Array, Uint32Array, Int8Array, Int16Array, Int32Array, Float32Array, Float64Array};
        if (typeof BigInt64Array !== 'undefined') constructors.BigInt64Array = BigInt64Array;
        if (typeof BigUint64Array !== 'undefined') constructors.BigUint64Array = BigUint64Array;
        const Constructor = constructors[node.n];
        if (!Constructor) throw new TypeError('Unsupported stored typed array: ' + node.n);
        const buffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
        return new Constructor(buffer);
      }
      case 'array': return (node.v || []).map(decodeStorageNode);
      case 'object': {
        const result = {};
        for (const [key, value] of node.v || []) Object.defineProperty(result, key, {value: decodeStorageNode(value), enumerable: true, writable: true, configurable: true});
        return result;
      }
      default: return node;
    }
  };
  const decodeStored = value => value && typeof value === 'object' && value.__rikugan_storage_codec__ === 'v1' && Object.prototype.hasOwnProperty.call(value, 'value')
    ? decodeStorageNode(value.value) : value;
  const clone = value => decodeStored(encodeStored(value));
  const values = Object.create(null);
  for (const [key, value] of Object.entries(config.storage || {})) values[key] = decodeStored(value);
  const resources = config.resources || {};
  const listeners = new Map(), pendingWrites = new Map();
  let listenerSequence = 0, writeSequence = 0, storageRevision = -1;
  const own = (object, key) => Object.prototype.hasOwnProperty.call(object, key);
  const visibleValues = () => {
    const result = Object.assign(Object.create(null), values);
    for (const write of pendingWrites.values()) {
      if (write.deleting) delete result[write.key]; else result[write.key] = write.value;
    }
    return result;
  };
  const acceptSnapshot = snapshot => {
    if (!snapshot || typeof snapshot.revision !== 'number' || !snapshot.values || snapshot.revision < storageRevision) return;
    storageRevision = snapshot.revision;
    for (const key of Object.keys(values)) delete values[key];
    for (const [key, value] of Object.entries(snapshot.values)) values[key] = decodeStored(value);
  };
  const acceptChange = event => {
    if (!event || !event.changed) { acceptSnapshot(event); return; }
    if (event.revision <= storageRevision) return;
    storageRevision = event.revision;
    const oldValue = event.oldExists ? decodeStored(event.oldValue) : undefined;
    const newValue = event.newExists ? decodeStored(event.newValue) : undefined;
    if (event.newExists) values[event.key] = clone(newValue); else delete values[event.key];
    for (const [id, listener] of Array.from(listeners)) {
      if (listeners.has(id) && listener.key === event.key) {
        try { listener.callback(event.key, event.oldExists ? clone(oldValue) : undefined,
          event.newExists ? clone(newValue) : undefined, event.writer !== clientID); }
        catch (error) { console.error('[Rikugan GM listener]', error); }
      }
    }
  };
  // This function only exists in this script's isolated WKContentWorld. Native
  // delivery checks the script, profile, privacy bucket, frame and document id.
  globalThis.__rikuganStorageChange = (id, event) => {
    if (id === clientID && matched(location.href)) acceptChange(event);
  };
  const writeValue = (key, value, deleting = false) => {
    key = String(key);
    const copied = deleting ? undefined : clone(value);
    const encoded = deleting ? null : encodeStored(copied);
    const sequence = ++writeSequence;
    pendingWrites.set(sequence, {key, value: copied, deleting});
    let request;
    try { request = call(deleting ? 'deleteValue' : 'setValue', {key, value: encoded}); }
    catch (error) { pendingWrites.delete(sequence); return Promise.reject(error); }
    return Promise.resolve(request).then(result => {
      // Older bridges returned true; keep the shim testable without events.
      if (result === true) { if (deleting) delete values[key]; else values[key] = copied; }
      else acceptChange(result);
    }).finally(() => pendingWrites.delete(sequence));
  };
  const GM_addValueChangeListener = allowed('addValueChangeListener') ? (key, callback) => {
    if (typeof callback !== 'function') throw new TypeError('GM value-change callback must be a function');
    const id = ++listenerSequence; listeners.set(id, {key: String(key), callback}); return id;
  } : undefined;
  const GM_removeValueChangeListener = allowed('removeValueChangeListener') ? id => { listeners.delete(id); } : undefined;
  const GM_info = {
    scriptHandler: 'Rikugan', version: '0.4.0',
    script: { name: config.name, namespace: config.namespace || '', version: config.version, author: config.author || '', grants: config.grants, resources: Object.keys(resources) },
    scriptWillUpdate: false,
    capabilities: { unsafeWindow: config.isolated ? 'partial' : 'supported', GM_getResourceText: 'supported', GM_xmlhttpRequest: 'partial' }
  };
  const addStyle = css => {
    const style = document.createElement('style'); style.textContent = String(css);
    (document.head || document.documentElement).appendChild(style); return style;
  };
  const GM_addStyle = addStyle;
  const GM_log = (...args) => console.log('[Rikugan]', ...args);
  const GM_getValue = allowed('getValue') ? (key, fallback) => { const cache = visibleValues(); return own(cache, key) ? clone(cache[key]) : fallback; } : undefined;
  const GM_setValue = allowed('setValue') ? (key, value) => { void writeValue(key, value).catch(console.error); } : undefined;
  const GM_deleteValue = allowed('deleteValue') ? key => { void writeValue(key, null, true).catch(console.error); } : undefined;
  const GM_listValues = allowed('listValues') ? () => Object.keys(visibleValues()) : undefined;
  const GM_setClipboard = allowed('setClipboard') ? text => call('setClipboard', {text: String(text)}) : undefined;
  const GM_openInTab = allowed('openInTab') ? (url, options = {}) => call('openInTab', {url: String(url), background: options === true || options.active === false}) : undefined;
  const GM_getResourceText = allowed('getResourceText') ? name => resources[name] ? resources[name].text : undefined : undefined;
  const GM_getResourceURL = allowed('getResourceURL') ? name => resources[name] ? resources[name].url : undefined : undefined;
  const callbacks = Object.create(null);
  Object.defineProperty(globalThis, '__rikuganCommands', {value: callbacks, configurable: true});
  const GM_registerMenuCommand = allowed('registerMenuCommand') ? (title, callback) => {
    const id = config.id + '-' + Math.random().toString(36).slice(2);
    callbacks[id] = callback; void call('registerMenuCommand', {id, title: String(title)}).catch(console.error); return id;
  } : undefined;
  const GM_unregisterMenuCommand = allowed('unregisterMenuCommand') ? id => { delete callbacks[id]; return call('unregisterMenuCommand', {id}); } : undefined;
  const activeXHR = new Map();
  globalThis.__rikuganXHRProgress = (id, requestID, value) => {
    if (id === clientID && matched(location.href)) activeXHR.get(requestID)?.(value);
  };
  const encodeBody = async (details, headers) => {
    const body = details.data;
    if (body === undefined || body === null) return {};
    const hasType = () => Object.keys(headers).some(key => key.toLowerCase() === 'content-type');
    let blob;
    if (typeof body === 'string' && !details.binary) {
      if (new TextEncoder().encode(body).byteLength > 2000000) throw new Error('Request body exceeds 2 MB');
      return {data: body};
    }
    if (typeof URLSearchParams !== 'undefined' && body instanceof URLSearchParams) {
      if (!hasType()) headers['Content-Type'] = 'application/x-www-form-urlencoded;charset=UTF-8';
      const text = body.toString();
      if (text.length > 2000000) throw new Error('Request body exceeds 2 MB');
      return {data: text};
    }
    if (typeof FormData !== 'undefined' && body instanceof FormData) {
      const boundary = 'Rikugan-' + Math.random().toString(36).slice(2) + Date.now();
      const parts = [], quote = text => String(text).replace(/\r/g, '%0D').replace(/\n/g, '%0A').replace(/"/g, '%22');
      let count = 0, size = 0;
      for (const [key, value] of body.entries()) {
        if (++count > 64) throw new Error('FormData exceeds 64 fields');
        const file = value instanceof Blob;
        const header = '--' + boundary + '\r\nContent-Disposition: form-data; name="' + quote(key) + '"' +
          (file ? '; filename="' + quote(value.name || 'blob') + '"\r\nContent-Type: ' + (value.type || 'application/octet-stream') : '') + '\r\n\r\n';
        size += header.length + (file ? value.size : new TextEncoder().encode(String(value)).byteLength) + 2;
        if (size > 2000000) throw new Error('Request body exceeds 2 MB');
        parts.push(header, value, '\r\n');
      }
      parts.push('--' + boundary + '--\r\n');
      blob = new Blob(parts);
      if (!hasType()) headers['Content-Type'] = 'multipart/form-data; boundary=' + boundary;
    } else if (typeof body === 'string' && details.binary) {
      blob = new Blob([Uint8Array.from(body, character => character.charCodeAt(0) & 255)]);
    } else if (body instanceof Blob) {
      blob = body;
      if (!hasType() && body.type) headers['Content-Type'] = body.type;
    } else if (ArrayBuffer.isView(body) || Object.prototype.toString.call(body) === '[object ArrayBuffer]') {
      blob = new Blob([body]);
    } else throw new Error('Unsupported API: GM XHR body type; use text, Blob, ArrayBuffer, URLSearchParams or FormData');
    if (blob.size > 2000000) throw new Error('Request body exceeds 2 MB');
    const bytes = new Uint8Array(await blob.arrayBuffer());
    let binary = '';
    for (let offset = 0; offset < bytes.length; offset += 32768) binary += String.fromCharCode(...bytes.subarray(offset, offset + 32768));
    return {dataBase64: btoa(binary)};
  };
  const xhr = input => {
    const details = input || {}, id = Math.random().toString(36).slice(2) + '-' + Date.now();
    let finished = false, dispatched = false, timer, resolve, reject, previousState = 0;
    const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
    const callback = (name, value) => {
      try { if (typeof details[name] === 'function') details[name]({...value, context: details.context}); }
      catch (error) { console.error('[Rikugan GM XHR callback]', error); }
    };
    const state = value => {
      if (value.readyState !== previousState) { previousState = value.readyState; callback('onreadystatechange', value); }
    };
    const clean = () => { clearTimeout(timer); activeXHR.delete(id); };
    const fail = (kind, message) => {
      if (finished) return;
      finished = true; clean();
      const value = {readyState: 4, status: 0, error: String(message)};
      state(value); callback('on' + kind, value); callback('onloadend', value);
      const error = new Error(String(message)); error.name = kind === 'abort' ? 'AbortError' : kind === 'timeout' ? 'TimeoutError' : 'Error';
      reject(error);
    };
    const abortNative = () => {
      if (dispatched) { try { void call('abortRequest', {id}).catch(console.error); } catch (error) { console.error(error); } }
    };
    promise.abort = () => { if (!finished) { abortNative(); fail('abort', 'Request aborted'); } };
    activeXHR.set(id, value => { if (!finished) { state(value); if (value.readyState === 3) callback('onprogress', value); } });
    Promise.resolve().then(async () => {
      const type = details.responseType || 'text';
      if (!['text', 'json', 'arraybuffer', 'blob', 'document'].includes(type)) throw new Error('Unsupported API: GM XHR responseType ' + type);
      for (const option of ['synchronous', 'fetch', 'cookiePartition', 'proxy', 'user', 'password', 'overrideMimeType']) {
        if (details[option]) throw new Error('Unsupported API: GM XHR option ' + option);
      }
      if (details.redirect && details.redirect !== 'follow') throw new Error('Unsupported API: GM XHR redirect ' + details.redirect);
      if (details.cookie) throw new Error('Unsupported API: automatic cookie merging; GM XHR uses an ephemeral cookie-free session');
      const timeout = details.timeout === undefined ? 0 : Number(details.timeout);
      if (!Number.isFinite(timeout) || timeout < 0 || timeout > 120000) throw new Error('timeout must be 0–120000 milliseconds');
      if (finished) return;
      if (timeout > 0) timer = setTimeout(() => { abortNative(); fail('timeout', 'Request timed out'); }, timeout);
      if (details.headers != null && typeof details.headers !== 'object') throw new TypeError('headers must be an object');
      const headers = Object.fromEntries(Object.entries(details.headers || {}).map(([key, value]) => [key, String(value)]));
      const body = await encodeBody(details, headers);
      if (finished) return;
      state({readyState: 1, status: 0}); callback('onloadstart', {readyState: 1, status: 0});
      dispatched = true;
      const response = await call('xmlHttpRequest', {id, url: String(details.url), method: String(details.method || 'GET'), headers, timeout, ...body});
      if (finished) return;
      if (response.error) { fail(response.kind || 'error', response.error); return; }
      response.readyState = 4; response.response = response.responseText;
      if (type === 'json') { try { response.response = JSON.parse(response.responseText); } catch (_) { response.response = null; } }
      if (type === 'arraybuffer' || type === 'blob') {
        const bytes = Uint8Array.from(atob(response.responseBase64), character => character.charCodeAt(0));
        const mime = (response.responseHeaders || '').match(/^content-type:\s*([^\r\n]+)/im)?.[1] || '';
        response.response = type === 'blob' ? new Blob([bytes], {type: mime}) : bytes.buffer;
      }
      if (type === 'document') {
        response.responseXML = new DOMParser().parseFromString(response.responseText, /content-type:\s*text\/html/i.test(response.responseHeaders || '') ? 'text/html' : 'application/xml');
        response.response = response.responseXML;
      }
      delete response.responseBase64;
      response.context = details.context;
      finished = true; clean(); state(response); callback('onload', response); callback('onloadend', response); resolve(response);
    }).catch(error => fail('error', error));
    return promise;
  };
  const GM_xmlhttpRequest = allowed('xmlHttpRequest') ? details => {
    const request = xhr(details); request.catch(() => {}); return {abort: request.abort};
  } : undefined;
  const GM = {info: GM_info, addStyle, log: GM_log};
  if (allowed('getValue')) GM.getValue = async (key, fallback) => { const result = await call('getValue', {key: String(key)}); return result.exists ? clone(decodeStored(result.value)) : fallback; };
  if (allowed('setValue')) GM.setValue = (key, value) => writeValue(key, value);
  if (allowed('deleteValue')) GM.deleteValue = key => writeValue(key, null, true);
  if (allowed('listValues')) GM.listValues = () => call('listValues');
  if (allowed('addValueChangeListener')) GM.addValueChangeListener = async (key, callback) => GM_addValueChangeListener(key, callback);
  if (allowed('removeValueChangeListener')) GM.removeValueChangeListener = async id => GM_removeValueChangeListener(id);
  if (allowed('setClipboard')) GM.setClipboard = GM_setClipboard;
  if (allowed('openInTab')) GM.openInTab = GM_openInTab;
  if (allowed('registerMenuCommand')) GM.registerMenuCommand = GM_registerMenuCommand;
  if (allowed('unregisterMenuCommand')) GM.unregisterMenuCommand = GM_unregisterMenuCommand;
  if (allowed('xmlHttpRequest')) GM.xmlHttpRequest = xhr;
  if (allowed('getResourceText')) GM.getResourceText = async name => resources[name] ? resources[name].text : null;
  if (allowed('getResourceURL')) GM.getResourceURL = async name => resources[name] ? resources[name].url : null;
  const unsafeWindow = (() => {
    if (!config.isolated) return typeof window === 'undefined' ? globalThis : window;
    const evalInPage = code => {
      const el = document.createElement('script');
      el.textContent = String(code);
      (document.documentElement || document.head || document.body).appendChild(el);
      el.remove();
    };
    return new Proxy(Object.create(null), {
      get(_, prop) {
        if (prop === 'eval') return evalInPage;
        if (prop === Symbol.toPrimitive || prop === 'then' || prop === Symbol.toStringTag) return undefined;
        throw new Error('Unsupported API: isolated unsafeWindow.' + String(prop) + ' is Partial. Use unsafeWindow.eval(code).');
      },
      set(_, prop, value) {
        const json = JSON.stringify(value);
        if (json === undefined) throw new Error('Unsupported API: unsafeWindow assignment only accepts JSON values. Compatibility: Partial.');
        evalInPage('window[' + JSON.stringify(String(prop)) + '] = ' + json + ';');
        return true;
      }
    });
  })();
  const run = () => {
    try {
      /*__SOURCE__*/
    } catch (error) { console.error('[Rikugan userscript: ' + config.name + ']', error); }
  };
  let ranFor = '';
  const schedule = () => {
    if (config.runAt === 'document-body') {
      if (typeof document === 'undefined' || document.body) run();
      else {
        let done = false;
        const ready = () => {
          if (done || !document.body) return;
          done = true; observer.disconnect(); document.removeEventListener('DOMContentLoaded', ready); run();
        };
        const observer = new MutationObserver(ready);
        observer.observe(document, {childList: true, subtree: true});
        document.addEventListener('DOMContentLoaded', ready, {once: true});
      }
    } else if (config.runAt === 'document-idle') {
      if (typeof requestIdleCallback === 'function') requestIdleCallback(run, {timeout: 1000});
      else setTimeout(run, 1);
    } else run();
  };
  const boot = href => {
    let current = href;
    try { current = href || location.href; if (!matched(current)) return; } catch (_) { return; }
    if (ranFor === current) return;
    ranFor = current;
    schedule();
  };
  // @grant none scripts share the page world: registering one must not replace
  // every preceding script's SPA URL hook.
  const hooks = globalThis.__rikuganURLChangeHooks || (globalThis.__rikuganURLChangeHooks = Object.create(null));
  hooks[config.id] = () => { try { boot(location.href); } catch (error) { console.error(error); } };
  globalThis.__rikuganOnURLChange = () => Object.values(hooks).forEach(hook => hook());
  const observeStorage = () => {
    if (config.isolated && matched(location.href) && ['getValue', 'setValue', 'deleteValue', 'listValues', 'addValueChangeListener'].some(allowed)) {
      void call('observeStorage').then(acceptSnapshot).catch(console.error);
    }
  };
  observeStorage();
  if (typeof addEventListener === 'function') addEventListener('pageshow', event => { if (event.persisted) observeStorage(); });
  try { boot(location.href); } catch (_) {}
})();
