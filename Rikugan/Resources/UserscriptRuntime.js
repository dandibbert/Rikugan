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
  if (!['http:', 'https:'].includes(location.protocol)) return;
  if (!(config.matches.some(p => match(p, location.href)) || config.includes.some(p => glob(p, location.href)))) return;
  if (config.excludes.some(p => glob(p, location.href)) || config.excludeMatches.some(p => match(p, location.href))) return;
  const allowed = name => config.grants.includes('GM.' + name) || config.grants.includes('GM_' + (name === 'xmlHttpRequest' ? 'xmlhttpRequest' : name));
  const call = (operation, args = {}) => window.webkit.messageHandlers[config.handler].postMessage({operation, args});
  const values = Object.assign(Object.create(null), config.storage || {});
  const clone = value => value === undefined ? undefined : JSON.parse(JSON.stringify(value));
  const GM_info = {scriptHandler: 'Rikugan', version: '0.1.0', script: {name: config.name, version: config.version, grants: config.grants}, scriptWillUpdate: false};
  const addStyle = css => {
    const style = document.createElement('style'); style.textContent = String(css);
    (document.head || document.documentElement).appendChild(style); return style;
  };
  const GM_addStyle = addStyle;
  const GM_log = (...args) => console.log('[Rikugan]', ...args);
  const GM_getValue = allowed('getValue') ? (key, fallback) => Object.prototype.hasOwnProperty.call(values, key) ? clone(values[key]) : fallback : undefined;
  const GM_setValue = allowed('setValue') ? (key, value) => {
    values[String(key)] = clone(value); void call('setValue', {key: String(key), value}).catch(console.error);
  } : undefined;
  const GM_deleteValue = allowed('deleteValue') ? key => {
    delete values[String(key)]; void call('deleteValue', {key: String(key)}).catch(console.error);
  } : undefined;
  const GM_listValues = allowed('listValues') ? () => Object.keys(values) : undefined;
  const GM_setClipboard = allowed('setClipboard') ? text => call('setClipboard', {text: String(text)}) : undefined;
  const GM_openInTab = allowed('openInTab') ? (url, options = {}) => call('openInTab', {url: String(url), background: options === true || options.active === false}) : undefined;
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
  if (allowed('getValue')) GM.getValue = async (key, fallback) => { const value = await call('getValue', {key: String(key)}); return value === null ? fallback : value; };
  if (allowed('setValue')) GM.setValue = async (key, value) => { values[String(key)] = clone(value); return call('setValue', {key: String(key), value}); };
  if (allowed('deleteValue')) GM.deleteValue = async key => { delete values[String(key)]; return call('deleteValue', {key: String(key)}); };
  if (allowed('listValues')) GM.listValues = () => call('listValues');
  if (allowed('setClipboard')) GM.setClipboard = GM_setClipboard;
  if (allowed('openInTab')) GM.openInTab = GM_openInTab;
  if (allowed('registerMenuCommand')) GM.registerMenuCommand = GM_registerMenuCommand;
  if (allowed('unregisterMenuCommand')) GM.unregisterMenuCommand = GM_unregisterMenuCommand;
  if (allowed('xmlHttpRequest')) GM.xmlHttpRequest = xhr;
  const run = () => {
    try {
      /*__SOURCE__*/
    } catch (error) { console.error('[Rikugan userscript: ' + config.name + ']', error); }
  };
  if (config.runAt === 'document-idle') {
    if (typeof requestIdleCallback === 'function') requestIdleCallback(run, {timeout: 1000});
    else setTimeout(run, 1);
  } else run();
})();
