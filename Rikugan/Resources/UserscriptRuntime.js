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
  const xhr = details => {
    const id = Math.random().toString(36).slice(2);
    const args = {id, url: String(details.url), method: details.method || 'GET', headers: details.headers || {}, data: typeof details.data === 'string' ? details.data : null};
    let aborted = false;
    pendingXHR[id] = details;
    const promise = call('xmlHttpRequest', args).then(response => {
      delete pendingXHR[id];
      if (aborted) return;
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
      pageEval('if(!window.__rgBridge){window.__rgHandles={0:window};window.__rgNext=1;window.__rgPack=function(v){if(v===undefined)return{t:"val",u:1};if(v===null||typeof v==="string"||typeof v==="number"||typeof v==="boolean")return{t:"val",v:v};if(typeof v==="function"||(v&&typeof v==="object")){var id=window.__rgNext++;window.__rgHandles[id]=v;return{t:typeof v==="function"?"fn":"obj",id:id};}return{t:"err",e:"not transferable"};};window.__rgUnpack=function(a){if(a&&a.t==="ref")return window.__rgHandles[a.id];return a?a.v:a;};window.__rgBridge=function(op){var result;try{if(op.op==="get")result=window.__rgPack(window.__rgHandles[op.id][op.prop]);else if(op.op==="set"){window.__rgHandles[op.id][op.prop]=window.__rgUnpack(op.value);result={t:"ok"};}else if(op.op==="call"){var args=(op.args||[]).map(window.__rgUnpack);result=window.__rgPack(window.__rgHandles[op.id].apply(window.__rgHandles[op.recv]||window.__rgHandles[op.id],args));}else result={t:"err",e:"unknown"};}catch(e){result={t:"err",e:String(e&&e.message||e)};}document.documentElement.setAttribute("data-rg-uw",JSON.stringify(result));};}window.__rgBridge(' + JSON.stringify(op) + ');');
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
      try { JSON.stringify(value); } catch (_) { throw new Error('Unsupported API: unsafeWindow assignment only accepts JSON values or page object handles. Compatibility: Partial.'); }
      if (typeof value === 'function') throw new Error('Unsupported API: unsafeWindow cannot send an isolated function into the page. Compatibility: Partial.');
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
    try {
      /*__SOURCE__*/
    } catch (error) { console.error('[Rikugan userscript: ' + config.name + ']', error); }
  };
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
