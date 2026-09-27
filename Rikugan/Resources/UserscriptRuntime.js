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
  const matched = href => ['http:', 'https:'].includes(new URL(href).protocol)
    && (config.matches.some(p => match(p, href)) || config.includes.some(p => glob(p, href)))
    && !config.excludes.some(p => glob(p, href)) && !config.excludeMatches.some(p => match(p, href));
  const allowed = name => config.grants.includes('GM.' + name) || config.grants.includes('GM_' + (name === 'xmlHttpRequest' ? 'xmlhttpRequest' : name));
  const call = (operation, args = {}) => window.webkit.messageHandlers[config.handler].postMessage({operation, args});
  const values = Object.assign(Object.create(null), config.storage || {});
  const resources = config.resources || {};
  const clone = value => value === undefined ? undefined : JSON.parse(JSON.stringify(value));
  const GM_info = {
    scriptHandler: 'Rikugan', version: '0.2.0',
    script: { name: config.name, namespace: config.namespace || '', version: config.version, author: config.author || '', grants: config.grants, resources: Object.keys(resources) },
    scriptWillUpdate: false,
    capabilities: { unsafeWindow: config.isolated ? 'partial' : 'supported', GM_getResourceText: 'supported', GM_xmlhttpRequest: 'partial', GM_registerMenuCommand: 'supported' }
  };
  const addStyle = css => {
    const style = document.createElement('style'); style.textContent = String(css);
    (document.head || document.documentElement).appendChild(style); return style;
  };
  const GM_addStyle = addStyle;
  const GM_log = (...args) => console.log('[Rikugan]', ...args);
  const GM_getValue = allowed('getValue') ? (key, fallback) => Object.prototype.hasOwnProperty.call(values, key) ? clone(values[key]) : fallback : undefined;
  const listeners = Object.create(null);
  const emitValue = (key, oldValue, newValue, remote) => {
    (listeners[String(key)] || []).forEach(item => { try { item.callback(String(key), oldValue, newValue, remote); } catch (error) { console.error(error); } });
  };
  globalThis.__rikuganValueChanged = (key, value, remote) => {
    const oldValue = values[String(key)];
    if (value === null) delete values[String(key)]; else values[String(key)] = value;
    emitValue(key, oldValue, values[String(key)], remote !== false);
  };
  const GM_setValue = allowed('setValue') ? (key, value) => {
    const name = String(key);
    const oldValue = values[name];
    values[name] = clone(value);
    emitValue(name, oldValue, values[name], false);
    void call('setValue', {key: name, value}).catch(console.error);
  } : undefined;
  const GM_deleteValue = allowed('deleteValue') ? key => {
    const name = String(key);
    const oldValue = values[name];
    delete values[name];
    emitValue(name, oldValue, undefined, false);
    void call('deleteValue', {key: name}).catch(console.error);
  } : undefined;
  const GM_listValues = allowed('listValues') ? () => Object.keys(values) : undefined;
  let listenerSeq = 0;
  const GM_addValueChangeListener = allowed('addValueChangeListener') ? (name, callback) => {
    const id = String(++listenerSeq);
    const key = String(name);
    listeners[key] = listeners[key] || [];
    listeners[key].push({ id, callback });
    return id;
  } : undefined;
  const GM_removeValueChangeListener = allowed('removeValueChangeListener') ? id => {
    Object.keys(listeners).forEach(key => { listeners[key] = (listeners[key] || []).filter(item => item.id !== String(id)); });
  } : undefined;
  const GM_setClipboard = allowed('setClipboard') ? text => call('setClipboard', {text: String(text)}) : undefined;
  const GM_openInTab = allowed('openInTab') ? (url, options = {}) => call('openInTab', {url: String(url), background: options === true || options.active === false}) : undefined;
  const GM_getResourceText = allowed('getResourceText') ? name => resources[name] ? resources[name].text : undefined : undefined;
  const GM_getResourceURL = allowed('getResourceURL') ? name => resources[name] ? resources[name].url : undefined : undefined;
  const callbacks = (globalThis.__rikuganCommands && typeof globalThis.__rikuganCommands === 'object') ? globalThis.__rikuganCommands : Object.create(null);
  Object.defineProperty(globalThis, '__rikuganCommands', {value: callbacks, configurable: true});
  const menuAllowed = allowed('registerMenuCommand') || (config.grants || []).includes('none');
  const GM_registerMenuCommand = menuAllowed ? (title, callback) => {
    const id = config.id + '-' + Math.random().toString(36).slice(2);
    callbacks[id] = callback; void call('registerMenuCommand', {id, title: String(title)}).catch(console.error); return id;
  } : undefined;
  const GM_unregisterMenuCommand = (menuAllowed || allowed('unregisterMenuCommand')) ? id => { delete callbacks[id]; return call('unregisterMenuCommand', {id}); } : undefined;
  const pendingXHR = Object.create(null);
  globalThis.__rikuganXHREvent = event => {
    const details = pendingXHR[event && event.id];
    if (!details || typeof details.onprogress !== 'function') return;
    details.onprogress({ lengthComputable: Number(event.total) > 0, loaded: Number(event.loaded) || 0, total: Number(event.total) || 0 });
  };
  const headerMap = value => {
    const headers = {};
    if (value && typeof value === 'object') Object.keys(value).forEach(key => { headers[key] = String(value[key]); });
    return headers;
  };
  const hasType = headers => Object.keys(headers).some(key => key.toLowerCase() === 'content-type');
  const textBytes = text => typeof TextEncoder === 'function' ? new TextEncoder().encode(text) : Uint8Array.from(unescape(encodeURIComponent(text)), c => c.charCodeAt(0));
  const b64 = bytes => {
    let binary = '';
    for (let index = 0; index < bytes.length; index += 0x8000) binary += String.fromCharCode.apply(null, bytes.subarray(index, index + 0x8000));
    return btoa(binary);
  };
  const joinBytes = chunks => {
    let total = 0;
    chunks.forEach(chunk => { total += chunk.length; });
    if (total > 8 * 1024 * 1024) throw new Error('请求体超过大小限制。');
    const bytes = new Uint8Array(total);
    let offset = 0;
    chunks.forEach(chunk => { bytes.set(chunk, offset); offset += chunk.length; });
    return bytes;
  };
  const encodeSync = data => {
    if (data == null) return { data: null };
    if (typeof data === 'string') return { data };
    if (typeof URLSearchParams !== 'undefined' && data instanceof URLSearchParams) return { data: data.toString(), contentType: 'application/x-www-form-urlencoded;charset=UTF-8' };
    return null;
  };
  const encodeAsync = async data => {
    if (typeof FormData !== 'undefined' && data instanceof FormData) {
      const boundary = '----RikuganForm' + Math.random().toString(16).slice(2);
      const chunks = [];
      for (const pair of data.entries()) {
        const name = String(pair[0]).replace(/[\r\n"]/g, '');
        const value = pair[1];
        if (typeof value === 'string') {
          chunks.push(textBytes('--' + boundary + '\r\nContent-Disposition: form-data; name="' + name + '"\r\n\r\n' + value + '\r\n'));
        } else {
          const filename = String((value && value.name) || 'blob').replace(/[\r\n"]/g, '');
          const type = String((value && value.type) || 'application/octet-stream').replace(/[\r\n]/g, '');
          chunks.push(textBytes('--' + boundary + '\r\nContent-Disposition: form-data; name="' + name + '"; filename="' + filename + '"\r\nContent-Type: ' + type + '\r\n\r\n'));
          chunks.push(new Uint8Array(typeof value.arrayBuffer === 'function' ? await value.arrayBuffer() : []));
          chunks.push(textBytes('\r\n'));
        }
      }
      chunks.push(textBytes('--' + boundary + '--\r\n'));
      return { dataBase64: b64(joinBytes(chunks)), contentType: 'multipart/form-data; boundary=' + boundary };
    }
    let bytes = null;
    let contentType = 'application/octet-stream';
    if (typeof Blob !== 'undefined' && data instanceof Blob) {
      bytes = new Uint8Array(await data.arrayBuffer());
      contentType = data.type || contentType;
    } else if (typeof ArrayBuffer !== 'undefined' && data instanceof ArrayBuffer) bytes = new Uint8Array(data);
    else if (typeof ArrayBuffer !== 'undefined' && ArrayBuffer.isView(data)) bytes = new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
    if (!bytes) return { data: null };
    if (bytes.length > 8 * 1024 * 1024) throw new Error('请求体超过大小限制。');
    return { dataBase64: b64(bytes), contentType };
  };
  const requestArgs = (details, id, encoded) => {
    const headers = headerMap(details.headers);
    if (encoded.contentType && !hasType(headers)) headers['Content-Type'] = encoded.contentType;
    const args = { id, url: String(details.url), method: details.method || 'GET', headers, data: encoded.data == null ? null : encoded.data };
    if (encoded.dataBase64) args.dataBase64 = encoded.dataBase64;
    if (encoded.contentType && !hasType(headerMap(details.headers))) args.contentType = encoded.contentType;
    return args;
  };
  const xhr = details => {
    const id = Math.random().toString(36).slice(2);
    let aborted = false;
    pendingXHR[id] = details;
    const sync = encodeSync(details && details.data);
    const outgoing = sync ? Promise.resolve(call('xmlHttpRequest', requestArgs(details, id, sync))) : encodeAsync(details && details.data).then(encoded => aborted ? null : call('xmlHttpRequest', requestArgs(details, id, encoded)));
    const promise = outgoing.then(response => {
      delete pendingXHR[id];
      if (aborted || !response) return;
      response.response = response.responseText;
      if (details.responseType === 'json') { try { response.response = JSON.parse(response.responseText); } catch (_) { response.response = null; } }
      if (details.responseType === 'arraybuffer' || details.responseType === 'blob') {
        const bytes = Uint8Array.from(atob(response.responseBase64), c => c.charCodeAt(0));
        response.response = details.responseType === 'blob' ? new Blob([bytes]) : bytes.buffer;
      }
      delete response.responseBase64;
      details.onload?.(response); return response;
    }).catch(error => { delete pendingXHR[id]; if (!aborted) details.onerror?.({error: String(error)}); throw error; });
    const abort = () => {
      if (aborted) return;
      aborted = true;
      delete pendingXHR[id];
      void call('abortRequest', {id}).catch(() => {});
      details.onabort?.({});
    };
    promise.abort = abort;
    return {promise, abort};
  };
  const GM_xmlhttpRequest = allowed('xmlHttpRequest') ? details => {
    const request = xhr(details); request.promise.catch(() => {}); return {abort: request.abort};
  } : undefined;
  const GM = {info: GM_info, addStyle, log: GM_log};
  if (allowed('getValue')) GM.getValue = async (key, fallback) => { const value = await call('getValue', {key: String(key)}); return value === null ? fallback : value; };
  if (allowed('setValue')) GM.setValue = async (key, value) => { values[String(key)] = clone(value); return call('setValue', {key: String(key), value}); };
  if (allowed('deleteValue')) GM.deleteValue = async key => { delete values[String(key)]; return call('deleteValue', {key: String(key)}); };
  if (allowed('listValues')) GM.listValues = () => call('listValues');
  if (allowed('addValueChangeListener')) GM.addValueChangeListener = GM_addValueChangeListener;
  if (allowed('removeValueChangeListener')) GM.removeValueChangeListener = GM_removeValueChangeListener;
  if (allowed('setClipboard')) GM.setClipboard = GM_setClipboard;
  if (allowed('openInTab')) GM.openInTab = GM_openInTab;
  if (menuAllowed) GM.registerMenuCommand = GM_registerMenuCommand;
  if (menuAllowed) GM.unregisterMenuCommand = GM_unregisterMenuCommand;
  if (allowed('xmlHttpRequest')) GM.xmlHttpRequest = details => xhr(details).promise;
  if (allowed('getResourceText')) GM.getResourceText = async name => resources[name] ? resources[name].text : null;
  if (allowed('getResourceURL')) GM.getResourceURL = async name => resources[name] ? resources[name].url : null;
  const unsafeWindow = (() => {
    if (!config.isolated) return typeof window === 'undefined' ? globalThis : window;
    const refs = typeof WeakMap === 'function' ? new WeakMap() : null;
    const isolatedFns = new Map();
    let isolatedSeq = 1;
    const reserved = new Set(['function','return','if','else','for','while','do','switch','case','break','continue','new','typeof','instanceof','void','delete','in','of','var','let','const','class','extends','super','this','true','false','null','undefined','try','catch','finally','throw','await','async','yield','default','with','debugger','import','export','from','as','get','set']);
    const globals = new Set(['window','document','console','Math','JSON','Object','Array','String','Number','Boolean','Date','RegExp','Error','Promise','Map','Set','WeakMap','WeakSet','Symbol','parseInt','parseFloat','isNaN','isFinite','NaN','Infinity','arguments','encodeURIComponent','decodeURIComponent','encodeURI','decodeURI','setTimeout','clearTimeout','setInterval','clearInterval','fetch','XMLHttpRequest','navigator','location','history','localStorage','sessionStorage','atob','btoa','Intl','Reflect','Proxy','ArrayBuffer','Uint8Array','DataView','URL','URLSearchParams','Headers','Request','Response','FormData','Blob','File','Event','CustomEvent','Element','Node','HTMLElement','MutationObserver','performance','crypto','queueMicrotask','requestAnimationFrame','cancelAnimationFrame','alert','confirm','prompt','globalThis','self','top','parent','frames']);
    const installInvoke = () => {
      const node = typeof document === 'undefined' ? null : document.documentElement;
      if (!node) return;
      node.__rgInvoke = (id, args) => {
        const fn = isolatedFns.get(id);
        if (typeof fn !== 'function') return { t: 'err', e: 'missing function' };
        try {
          const unpacked = (args || []).map(item => item && item.t === 'val' ? (item.u ? undefined : item.v) : item && item.v);
          const value = fn.apply(undefined, unpacked);
          if (typeof value === 'undefined') return { t: 'val', u: 1 };
          if (value === null || typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') return { t: 'val', v: value };
          if (jsonData(value)) { try { return { t: 'val', v: JSON.parse(JSON.stringify(value)) }; } catch (_) { return { t: 'val', u: 1 }; } }
          return { t: 'val', u: 1 };
        } catch (error) { return { t: 'err', e: String(error && error.message || error) }; }
      };
      globalThis.__rikuganInvokeIsolated = (id, args) => node.__rgInvoke(id, args);
      if (!node.__rgInvokeBound && typeof node.addEventListener === 'function') {
        node.__rgInvokeBound = true;
        node.addEventListener('rg-iso-call', () => {
          let payload = {};
          try { payload = JSON.parse(node.getAttribute('data-rg-iso') || '{}'); } catch (_) { payload = {}; }
          node.setAttribute('data-rg-iso-result', JSON.stringify(node.__rgInvoke(payload.id, payload.args || [])));
        });
      }
    };
    const addParams = (declared, list) => String(list || '').split(',').forEach(part => {
      const name = part.replace(/=[\s\S]*$/, '').replace(/^\.\.\./, '').trim();
      if (/^[A-Za-z_$][\w$]*$/.test(name)) declared.add(name);
    });
    const freeNames = source => {
      let scan = source.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/(^|[^:])\/\/.*$/gm, '$1 ');
      scan = scan.replace(/'(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*"|`(?:\\.|[^`\\])*`/g, ' ');
      const declared = new Set();
      const named = scan.match(/^(?:async\s+)?function\s+([A-Za-z_$][\w$]*)/);
      if (named) declared.add(named[1]);
      const header = scan.match(/^(?:async\s+)?function\s*[^(]*\(([^)]*)\)/) || scan.match(/^(?:async\s*)?\(([^)]*)\)\s*=>/) || scan.match(/^(?:async\s+)?([A-Za-z_$][\w$]*)\s*=>/);
      if (header) addParams(declared, header[1]);
      scan.replace(/\bfunction\s*[^(]*\(([^)]*)\)/g, (_, params) => { addParams(declared, params); return ' '; });
      scan.replace(/\b(?:var|let|const|function|class)\s+([A-Za-z_$][\w$]*)/g, (_, name) => { declared.add(name); return ' '; });
      scan = scan.replace(/\.[A-Za-z_$][\w$]*/g, '');
      const ids = scan.match(/\b[A-Za-z_$][\w$]*/g) || [];
      const free = [];
      for (const name of ids) {
        if (declared.has(name) || reserved.has(name) || globals.has(name) || free.indexOf(name) >= 0) continue;
        free.push(name);
      }
      return free;
    };
    const jsonData = value => {
      if (value === null) return true;
      const kind = typeof value;
      if (kind === 'string' || kind === 'boolean') return true;
      if (kind === 'number') return Number.isFinite(value);
      if (kind !== 'object') return false;
      if (Array.isArray(value)) return value.every(item => item !== undefined && jsonData(item));
      const proto = Object.getPrototypeOf(value);
      if (proto !== Object.prototype && proto !== null) return false;
      return Object.keys(value).every(key => value[key] !== undefined && jsonData(value[key]));
    };
    const jsonLiteral = (value, seen) => {
      if (value === undefined) return 'undefined';
      if (typeof value === 'function') return serializableSource(value, seen);
      if (value === null) return 'null';
      const kind = typeof value;
      if (kind === 'string' || kind === 'boolean') return JSON.stringify(value);
      if (kind === 'number') return Number.isFinite(value) ? String(value) : null;
      if (kind !== 'object' || !jsonData(value)) return null;
      try { return JSON.stringify(value); } catch (_) { return null; }
    };
    const serializableSource = (fn, seen) => {
      if (!fn || seen.has(fn)) return null;
      let source = '';
      try { source = Function.prototype.toString.call(fn); } catch (_) { return null; }
      if (!source || source.indexOf('[native code]') >= 0 || source.length > 8000) return null;
      const free = freeNames(source);
      if (!free.length) return source;
      if (free.length > 24) return null;
      const next = new Set(seen);
      next.add(fn);
      const read = globalThis.__rikuganReadLocal;
      if (typeof read !== 'function') return null;
      const lines = [];
      for (const name of free) {
        const value = read(name);
        if (value === read.missing) return null;
        const literal = jsonLiteral(value, next);
        if (literal == null) return null;
        lines.push('var ' + name + '=' + literal + ';');
      }
      return '(function(){' + lines.join('') + 'return (' + source + ');})()';
    };
    const pageEval = code => {
      const doc = typeof document === 'undefined' ? null : document;
      if (!doc || typeof doc.createElement !== 'function' || !doc.documentElement) {
        throw new Error('Unsupported API: isolated unsafeWindow is Partial without a document bridge.');
      }
      const el = doc.createElement('script');
      el.textContent = String(code);
      doc.documentElement.appendChild(el);
      if (typeof el.remove === 'function') el.remove();
    };
    const bridge = op => {
      pageEval('if(!window.__rgBridge){window.__rgHandles={0:window};window.__rgNext=1;window.__rgPlain=function(v){if(!v||typeof v!=="object")return false;if(typeof v.nodeType==="number")return false;if(Array.isArray(v)){for(var i=0;i<v.length;i++){var item=v[i];if(item===undefined||typeof item==="function")return false;if(item&&typeof item==="object"&&!window.__rgPlain(item))return false;}return true;}var proto=Object.getPrototypeOf(v);if(proto!==null){var ctor=proto.constructor;var name=ctor&&ctor.name;if(name&&name!=="Object")return false;}var keys=Object.keys(v);for(var j=0;j<keys.length;j++){var field=v[keys[j]];if(field===undefined||typeof field==="function")return false;if(field&&typeof field==="object"&&!window.__rgPlain(field))return false;}return true;};window.__rgPack=function(v){if(v===undefined)return{t:"val",u:1};if(v===null||typeof v==="string"||typeof v==="number"||typeof v==="boolean")return{t:"val",v:v};if(window.__rgPlain(v)){try{return{t:"val",v:JSON.parse(JSON.stringify(v))};}catch(e){}}if(typeof v==="function"||(v&&typeof v==="object")){var id=window.__rgNext++;window.__rgHandles[id]=v;return{t:typeof v==="function"?"fn":"obj",id:id};}return{t:"err",e:"not transferable"};};window.__rgUnpack=function(a){if(!a)return a;if(a.t==="ref")return window.__rgHandles[a.id];if(a.t==="src"){try{return (0,eval)("("+a.v+")");}catch(e){return function(){throw e;};}}if(a.t==="iso")return window.__rgMakeStub(a.id);if(a.t==="val")return a.u?undefined:a.v;return a.v;};window.__rgResults=window.__rgResults||{};window.__rgInvoke=function(id,args){var node=document.documentElement;if(node&&typeof node.__rgInvoke==="function")return node.__rgInvoke(id,args);try{if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.rikuganPage)window.webkit.messageHandlers.rikuganPage.postMessage({action:"iso-call",handler:window.__rgScript||"",id:id,args:args||[]});}catch(e){}if(node&&node.dispatchEvent){if(node.removeAttribute)node.removeAttribute("data-rg-iso-result");node.setAttribute("data-rg-iso",JSON.stringify({id:id,args:args||[]}));node.dispatchEvent(new Event("rg-iso-call"));try{var raw=node.getAttribute("data-rg-iso-result");if(raw){var parsed=JSON.parse(raw);window.__rgResults[String(id)]=parsed;return parsed;}}catch(e){return {t:"err",e:"callback failed"};}}return {t:"pending"};};window.__rgMakeStub=function(id){return function(){var args=Array.prototype.slice.call(arguments).map(window.__rgPack);var result=window.__rgInvoke(id,args);if(result&&result.t==="err")throw new Error(result.e||"isolated call failed");if(result&&result.t==="pending")return undefined;return window.__rgUnpack(result);};};window.__rgScript=window.__rgScript||' + JSON.stringify(config.handler) + ';window.__rgBridge=function(op){var result;try{if(op.op==="get")result=window.__rgPack(window.__rgHandles[op.id][op.prop]);else if(op.op==="set"){window.__rgHandles[op.id][op.prop]=window.__rgUnpack(op.value);result={t:"ok"};}else if(op.op==="call"){var args=(op.args||[]).map(window.__rgUnpack);result=window.__rgPack(window.__rgHandles[op.id].apply(window.__rgHandles[op.recv]||window.__rgHandles[op.id],args));}else result={t:"err",e:"unknown"};}catch(e){result={t:"err",e:String(e&&e.message||e)};}document.documentElement.setAttribute("data-rg-uw",JSON.stringify(result));};}window.__rgBridge(' + JSON.stringify(op) + ');');
      const raw = document.documentElement.getAttribute('data-rg-uw');
      if (document.documentElement.removeAttribute) document.documentElement.removeAttribute('data-rg-uw');
      let payload = {};
      try { payload = JSON.parse(raw || '{}'); } catch (_) { payload = { t: 'err', e: 'not JSON' }; }
      if (payload.t === 'err' || payload.e) throw new Error('Unsupported API: isolated unsafeWindow. ' + (payload.e || 'Partial') + ' Compatibility: Partial.');
      return payload;
    };
    const encode = value => {
      if (refs && value && (typeof value === 'object' || typeof value === 'function') && refs.has(value)) return { t: 'ref', id: refs.get(value) };
      if (typeof value === 'undefined') return { t: 'val', u: 1 };
      if (typeof value === 'function') {
        const source = serializableSource(value, new Set());
        if (source) return { t: 'src', v: source };
        installInvoke();
        const id = isolatedSeq++;
        isolatedFns.set(id, value);
        return { t: 'iso', id: id };
      }
      try { JSON.stringify(value); } catch (_) { throw new Error('Unsupported API: unsafeWindow assignment only accepts JSON values, page object handles, or functions. Compatibility: Partial.'); }
      return { t: 'val', v: value };
    };
    const wrap = (id, owner) => {
      const proxy = new Proxy(function () {}, {
        get(_, prop) {
          if (prop === 'then' || typeof prop === 'symbol') return undefined;
          const result = bridge({ op: 'get', id: id, prop: String(prop) });
          if (result.t === 'fn') return wrap(result.id, id);
          if (result.t === 'obj') return wrap(result.id);
          return result.u ? undefined : result.v;
        },
        set(_, prop, value) {
          bridge({ op: 'set', id: id, prop: String(prop), value: encode(value) });
          return true;
        },
        apply(_, __, args) {
          const result = bridge({ op: 'call', id: id, recv: owner == null ? id : owner, args: args.map(encode) });
          if (result.t === 'fn') return wrap(result.id, owner);
          if (result.t === 'obj') return wrap(result.id);
          return result.u ? undefined : result.v;
        }
      });
      if (refs) refs.set(proxy, id);
      return proxy;
    };
    return wrap(0);
  })();
  const run = () => {
    const __rgMissing = { __rgMissing: true };
    try {
      const __rgRead = eval("(function(__rgMissing,__rgDeclared){return function(name){try{if(!__rgDeclared.has(name)||!/^[A-Za-z_$][\\w$]*$/.test(name))return __rgMissing;return eval(name);}catch(e){return __rgMissing;}};})");
      globalThis.__rikuganReadLocal = __rgRead(__rgMissing, __rgDeclared);
      globalThis.__rikuganReadLocal.missing = __rgMissing;
      /*__SOURCE__*/
    } catch (error) { console.error('[Rikugan userscript: ' + config.name + ']', error); }
  };
  const __rgDeclared = new Set();
  try {
    Function.prototype.toString.call(run).replace(/\b(?:var|let|const|function|class)\s+([A-Za-z_$][\w$]*)/g, (_, name) => {
      if (!String(name).startsWith('__rg')) __rgDeclared.add(name);
      return '';
    });
  } catch (_) {}
  let ranFor = '';
  const schedule = () => {
    if (config.runAt === 'document-body') {
      if (typeof document === 'undefined' || document.body) run();
      else document.addEventListener('DOMContentLoaded', run, {once: true});
    } else if (config.runAt === 'document-idle') {
      if (typeof requestIdleCallback === 'function') requestIdleCallback(run, {timeout: 1000});
      else setTimeout(run, 1);
    } else run();
  };
  const boot = href => {
    let current = href;
    try {
      if (config.noFrames && typeof window !== 'undefined' && window.top && window.top !== window) return;
      current = href || location.href;
      if (!matched(current)) return;
    } catch (_) { return; }
    if (ranFor === current) return;
    ranFor = current;
    schedule();
  };
  globalThis.__rikuganOnURLChange = () => { try { boot(location.href); } catch (error) { console.error(error); } };
  try { boot(location.href); } catch (_) {}
})();
