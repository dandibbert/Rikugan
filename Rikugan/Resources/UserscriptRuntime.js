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
  const values = Object.assign(Object.create(null), config.storage || {});
  const resources = config.resources || {};
  const clone = value => value === undefined ? undefined : JSON.parse(JSON.stringify(value));
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
    Object.assign(values, snapshot.values);
  };
  const acceptChange = event => {
    if (!event || !event.changed) { acceptSnapshot(event); return; }
    if (event.revision <= storageRevision) return;
    storageRevision = event.revision;
    if (event.newExists) values[event.key] = clone(event.newValue); else delete values[event.key];
    for (const [id, listener] of Array.from(listeners)) {
      if (listeners.has(id) && listener.key === event.key) {
        try { listener.callback(event.key, event.oldExists ? clone(event.oldValue) : undefined,
          event.newExists ? clone(event.newValue) : undefined, event.writer !== clientID); }
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
    if (!deleting && copied === undefined) return Promise.reject(new TypeError('GM storage accepts JSON values, not undefined'));
    const sequence = ++writeSequence;
    pendingWrites.set(sequence, {key, value: copied, deleting});
    let request;
    try { request = call(deleting ? 'deleteValue' : 'setValue', {key, value: deleting ? null : copied}); }
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
  const xhr = details => {
    const args = {url: String(details.url), method: details.method || 'GET', headers: details.headers || {}, data: typeof details.data === 'string' ? details.data : null};
    let aborted = false;
    const promise = call('xmlHttpRequest', args).then(response => {
      if (aborted) return;
      response.response = response.responseText;
      if (details.responseType === 'json') { try { response.response = JSON.parse(response.responseText); } catch (_) { response.response = null; } }
      if (details.responseType === 'arraybuffer' || details.responseType === 'blob') {
        const bytes = Uint8Array.from(atob(response.responseBase64), c => c.charCodeAt(0));
        response.response = details.responseType === 'blob' ? new Blob([bytes]) : bytes.buffer;
      }
      delete response.responseBase64;
      details.onload?.(response); return response;
    }).catch(error => { if (!aborted) details.onerror?.({error: String(error)}); throw error; });
    promise.abort = () => { aborted = true; details.onabort?.({}); };
    return promise;
  };
  const GM_xmlhttpRequest = allowed('xmlHttpRequest') ? details => {
    const request = xhr(details); request.catch(() => {}); return {abort: request.abort};
  } : undefined;
  const GM = {info: GM_info, addStyle, log: GM_log};
  if (allowed('getValue')) GM.getValue = async (key, fallback) => { const result = await call('getValue', {key: String(key)}); return result.exists ? result.value : fallback; };
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
