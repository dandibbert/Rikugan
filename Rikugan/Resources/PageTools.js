(function (root) {
  'use strict';
  function cssEscape(value) {
    return String(value).replace(/[^A-Za-z0-9_-]/g, ch => '\\' + ch);
  }
  function attr(el, name) {
    if (!el || typeof el.getAttribute !== 'function') return '';
    return el.getAttribute(name) || '';
  }
  function stableClass(name) {
    if (!/^[A-Za-z_-][\w-]*$/.test(name)) return false;
    if (name.indexOf('__') >= 0 || name.length > 24) return false;
    return !/[0-9]{3,}/.test(name);
  }
  function classTokens(el) {
    if (!el || !el.classList) return [];
    return Array.from(el.classList).filter(stableClass).slice(0, 2);
  }
  function selector(el) {
    if (!el || el.nodeType !== 1) return '';
    if (el.id && /^[A-Za-z][\w:.-]*$/.test(el.id)) return '#' + cssEscape(el.id);
    const testId = attr(el, 'data-testid') || attr(el, 'data-test') || attr(el, 'data-id');
    if (testId && /^[\w:.-]{1,80}$/.test(testId)) return el.tagName.toLowerCase() + '[data-testid="' + testId.replace(/"/g, '') + '"]';
    const label = attr(el, 'aria-label');
    if (label && label.length < 60 && !/["\\]/.test(label)) return el.tagName.toLowerCase() + '[aria-label="' + label + '"]';
    const parts = [];
    let node = el;
    while (node && node.nodeType === 1 && parts.length < 5) {
      let part = String(node.tagName || 'div').toLowerCase();
      const classes = classTokens(node);
      if (classes.length) part += '.' + classes.map(cssEscape).join('.');
      const parent = node.parentElement;
      if (parent && parent.children) {
        const same = Array.from(parent.children).filter(child => child.tagName === node.tagName);
        if (same.length > 1) part += ':nth-of-type(' + (same.indexOf(node) + 1) + ')';
      }
      parts.unshift(part);
      node = parent;
    }
    return parts.join(' > ');
  }
  function ensureStyle(id, css) {
    const doc = root.document;
    if (!doc) return;
    let style = doc.getElementById(id);
    if (!css) { if (style) style.remove(); return; }
    if (!style) {
      style = doc.createElement('style');
      style.id = id;
      (doc.documentElement || doc.head || doc.body).appendChild(style);
    }
    style.textContent = css;
  }
  function installExtensionRelay() {
    if (!root || root.__rikuganExtensionRelay || typeof root.addEventListener !== 'function') return false;
    root.__rikuganExtensionRelay = true;
    root.addEventListener('message', function (event) {
      const data = event && event.data;
      if (!data || data.source !== 'rikugan-extension-host' || !data.payload) return;
      const payload = data.payload;
      const bridge = root.webkit && root.webkit.messageHandlers && root.webkit.messageHandlers.rikuganPage;
      if (!bridge || typeof bridge.postMessage !== 'function') {
        if (typeof root.postMessage === 'function') root.postMessage({ source: 'rikugan-extension-host-result', id: payload.id, error: 'no page bridge' }, '*');
        return;
      }
      try { bridge.postMessage({ action: 'extension-host', id: payload.id, api: payload.api, details: payload.details || {} }); }
      catch (error) {
        if (typeof root.postMessage === 'function') root.postMessage({ source: 'rikugan-extension-host-result', id: payload.id, error: String(error) }, '*');
      }
    });
    root.__rgExtHostDone = function (payload) {
      const data = payload || {};
      if (typeof root.postMessage === 'function') root.postMessage({ source: 'rikugan-extension-host-result', id: data.id, result: data.result, error: data.error || null }, '*');
    };
    return true;
  }
  function insertExtensionCSS(css) {
    const doc = root.document;
    if (!doc || typeof doc.createElement !== 'function') return false;
    const node = doc.createElement('style');
    node.setAttribute('data-rikugan-extension', 'css');
    node.textContent = String(css || '');
    const parent = doc.head || doc.documentElement;
    if (!parent || typeof parent.appendChild !== 'function') return false;
    parent.appendChild(node);
    return true;
  }
  function installClipboard(decision) {
    const mode = decision || 'ask';
    const clip = root.navigator && root.navigator.clipboard;
    if (!clip || typeof clip.readText !== 'function') return mode;
    if (mode === 'allow') return 'allow';
    if (mode === 'block') {
      clip.readText = () => Promise.reject(new Error('Blocked by Rikugan'));
      return 'block';
    }
    if (clip.__rgAsk) return 'ask';
    const original = clip.readText.bind(clip);
    clip.__rgOriginalRead = original;
    clip.__rgAsk = true;
    clip.readText = () => new Promise((resolve, reject) => {
      const id = 'c' + Math.random().toString(36).slice(2);
      root.__rgClipboard = root.__rgClipboard || {};
      root.__rgClipboard[id] = decisionName => {
        if (decisionName === 'allow') {
          clip.readText = clip.__rgOriginalRead;
          original().then(resolve, reject);
        } else reject(new Error('Blocked by Rikugan'));
      };
      post({ action: 'clipboard-read', id: id });
    });
    root.__rgClipboardDone = (id, decisionName) => {
      const fn = root.__rgClipboard && root.__rgClipboard[id];
      if (typeof fn === 'function') fn(decisionName);
    };
    return 'ask';
  }
  const darkRules = [
    'html{color-scheme:dark!important;background-color:#111111!important}',
    'body,article,main,section,header,footer,nav,aside,div,p,li,td,th,span,h1,h2,h3,h4,h5,h6,label,button,input,textarea,select,blockquote,pre,code,ul,ol,table,form,figcaption,summary{background-color:#161616!important;color:#e8e8e8!important;border-color:#3a3a3a!important}',
    'a,a span{color:#9ec1ff!important}',
    'img,video,picture,canvas,svg{background-color:transparent!important;color:unset!important;filter:none!important}'
  ].join('');
  function setAppearance(mode) {
    if (mode === 'on') ensureStyle('rikugan-dark', darkRules);
    else if (mode === 'auto') ensureStyle('rikugan-dark', '@media (prefers-color-scheme: dark){' + darkRules + '}');
    else ensureStyle('rikugan-dark', '');
  }
  function fontOverrideCSS(body, heading, mono, faceCSS) {
    const stack = name => JSON.stringify(String(name || '')) + ', sans-serif, "Apple Color Emoji", "Segoe UI Emoji", "Noto Color Emoji"';
    const lines = [];
    if (faceCSS) lines.push(faceCSS);
    if (body) lines.push('html,body,button,input,textarea,select{font-family:' + stack(body) + '}');
    if (heading) lines.push('h1,h2,h3,h4,h5,h6{font-family:' + stack(heading) + '}');
    if (mono) lines.push('pre,code,kbd,samp{font-family:' + JSON.stringify(String(mono)) + ', ui-monospace, SFMono-Regular, Menlo, monospace}');
    lines.push('.material-icons,.material-icons-outlined,.material-icons-round,.material-icons-sharp,.material-icons-two-tone{font-family:"Material Icons"!important}');
    lines.push('.material-symbols-outlined,.material-symbols-rounded,.material-symbols-sharp{font-family:"Material Symbols Outlined"!important}');
    lines.push('.fa,.fas,.far,.fal,.fad{font-family:"Font Awesome 6 Free","Font Awesome 5 Free"!important}');
    lines.push('.fab{font-family:"Font Awesome 6 Brands","Font Awesome 5 Brands"!important}');
    lines.push('.glyphicon{font-family:"Glyphicons Halflings"!important}');
    lines.push('.iconfont,[class*="iconfont"]{font-family:"iconfont"!important}');
    return lines.join('');
  }
  function setFont(body, faceCSS, heading, mono) {
    if (!body && !heading && !mono) { ensureStyle('rikugan-font', ''); return; }
    ensureStyle('rikugan-font', fontOverrideCSS(body, heading, mono, faceCSS));
  }
  function hostMatches(host, domain) {
    return host === domain || (!!domain && host.endsWith('.' + domain));
  }
  function hideNode(node) {
    if (node && node.style && node.style.setProperty) node.style.setProperty('display', 'none', 'important');
  }
  function queryAll(doc, selector) {
    try { return Array.from(doc.querySelectorAll(selector || '*')); } catch (error) { return []; }
  }
  function applyProcedural(doc, rule) {
    const kind = rule.kind || 'has-text';
    if (kind === 'xpath') {
      if (!doc.evaluate || !rule.text) return;
      const snapshot = doc.evaluate(rule.text, doc, null, 7, null);
      for (let index = 0; index < snapshot.snapshotLength; index += 1) hideNode(snapshot.snapshotItem(index));
      return;
    }
    const nodes = queryAll(doc, rule.selector || '*');
    if (kind === 'remove') { nodes.forEach(node => { if (node.remove) node.remove(); }); return; }
    if (kind === 'style') {
      nodes.forEach(node => { if (node.style) node.style.cssText = (node.style.cssText || '') + ';' + (rule.text || ''); });
      return;
    }
    if (kind === 'upward') {
      nodes.forEach(node => {
        let target = node;
        if (/^\d+$/.test(rule.text || '')) {
          let count = Number(rule.text);
          while (count > 0 && target.parentElement) { target = target.parentElement; count -= 1; }
        } else if (rule.text && node.closest) target = node.closest(rule.text) || node;
        hideNode(target);
      });
      return;
    }
    if (kind === 'matches-css') {
      const raw = String(rule.text || '');
      const splitAt = raw.indexOf(',') >= 0 ? raw.indexOf(',') : raw.indexOf(':');
      const prop = (splitAt >= 0 ? raw.slice(0, splitAt) : raw).trim();
      const expected = splitAt >= 0 ? raw.slice(splitAt + 1).trim() : '';
      nodes.forEach(node => {
        let value = '';
        try { value = root.getComputedStyle ? root.getComputedStyle(node).getPropertyValue(prop) : ''; } catch (error) { value = ''; }
        if (!value && node.style) value = node.style[prop] || '';
        if (!expected || String(value).indexOf(expected) >= 0) hideNode(node);
      });
      return;
    }
    nodes.forEach(node => {
      const text = node.textContent || '';
      if (rule.text && text.indexOf(rule.text) < 0) return;
      hideNode(node);
    });
  }
  function propertyChain(path) {
    const parts = String(path || '').split('.').filter(Boolean);
    if (!parts.length) return null;
    let obj = root;
    for (let index = 0; index < parts.length - 1; index += 1) {
      if (obj[parts[index]] == null) obj[parts[index]] = {};
      obj = obj[parts[index]];
    }
    return { obj: obj, key: parts[parts.length - 1] };
  }
  function constantValue(raw) {
    if (raw === 'undefined') return undefined;
    if (raw === 'null') return null;
    if (raw === 'false') return false;
    if (raw === 'true') return true;
    if (raw === 'noopFunc' || raw === 'emptyFunc') return function () {};
    if (raw === "''" || raw === '""') return '';
    if (raw != null && /^-?\d+(?:\.\d+)?$/.test(String(raw))) return Number(raw);
    return raw;
  }
  function pruneKeys(value, keys) {
    if (!value || typeof value !== 'object') return;
    if (Array.isArray(value)) { value.forEach(item => pruneKeys(item, keys)); return; }
    keys.forEach(key => { if (Object.prototype.hasOwnProperty.call(value, key)) delete value[key]; });
    Object.keys(value).forEach(key => pruneKeys(value[key], keys));
  }
  function pruneJSONText(text, keys) {
    try {
      const value = JSON.parse(text);
      pruneKeys(value, keys);
      return JSON.stringify(value);
    } catch (error) { return text; }
  }
  function installJSONPrune(win, keys, needle) {
    if (!win || !keys.length) return;
    win.__rgPruneRules = win.__rgPruneRules || [];
    win.__rgPruneRules.push({ keys: keys, needle: needle || '' });
    if (win.__rgPruneHook) return;
    win.__rgPruneHook = true;
    const rewrite = (text, url) => {
      let output = String(text == null ? '' : text);
      (win.__rgPruneRules || []).forEach(rule => {
        if (rule.needle && String(url || '').indexOf(rule.needle) < 0) return;
        output = pruneJSONText(output, rule.keys);
      });
      return output;
    };
    if (typeof win.fetch === 'function') {
      const original = win.fetch;
      win.fetch = function (input) {
        const url = typeof input === 'string' ? input : (input && input.url) || '';
        const pending = original.apply(this, arguments);
        if (!pending || typeof pending.then !== 'function') return pending;
        return pending.then(response => {
          if (!response || typeof response.text !== 'function') return response;
          return response.text().then(text => {
            const next = rewrite(text, url);
            if (typeof win.Response === 'function') return new win.Response(next, { status: response.status || 200, headers: response.headers });
            return { status: response.status || 200, headers: response.headers, text: () => Promise.resolve(next) };
          });
        });
      };
    }
    const XHR = win.XMLHttpRequest;
    if (XHR && XHR.prototype && XHR.prototype.send && XHR.prototype.open) {
      const open = XHR.prototype.open;
      const send = XHR.prototype.send;
      XHR.prototype.open = function (method, url) { this.__rgPruneURL = url; return open.apply(this, arguments); };
      XHR.prototype.send = function () {
        this.addEventListener && this.addEventListener('readystatechange', () => {
          if (this.readyState !== 4 || this.__rgPruned) return;
          const raw = this.responseText;
          if (typeof raw !== 'string') return;
          const next = rewrite(raw, this.__rgPruneURL || '');
          if (next === raw) return;
          this.__rgPruned = true;
          try { Object.defineProperty(this, 'responseText', { configurable: true, get() { return next; } }); } catch (error) {}
        });
        return send.apply(this, arguments);
      };
    }
  }
  function applyScriptlets(rules) {
    const key = JSON.stringify(rules || []);
    if (root.__rgScriptletKey === key) return;
    root.__rgScriptletKey = key;
    const host = (root.location && root.location.hostname) || '';
    (rules || []).forEach(rule => {
      const domains = rule.domains || [];
      if (domains.length && !domains.some(domain => hostMatches(host, domain))) return;
      const name = rule.name;
      const args = rule.args || [];
      if (name === 'abort-on-property-read' || name === 'abort-on-property-write') {
        const hit = propertyChain(args[0]);
        if (!hit) return;
        const desc = name === 'abort-on-property-read'
          ? { configurable: true, get() { throw new ReferenceError(args[0]); } }
          : { configurable: true, set() { throw new TypeError(args[0]); } };
        try { Object.defineProperty(hit.obj, hit.key, desc); } catch (error) {}
      } else if (name === 'set-constant') {
        const hit = propertyChain(args[0]);
        if (!hit) return;
        const value = constantValue(args[1]);
        try { Object.defineProperty(hit.obj, hit.key, { configurable: true, get() { return value; }, set() {} }); } catch (error) {}
      } else if (name === 'prevent-fetch') {
        const pattern = args[0] || '';
        const original = root.fetch;
        root.fetch = function (input) {
          const url = typeof input === 'string' ? input : (input && input.url) || '';
          if (!pattern || String(url).indexOf(pattern) >= 0) return Promise.reject(new Error('blocked'));
          return original ? original.apply(this, arguments) : Promise.resolve();
        };
      } else if (name === 'prevent-xhr') {
        const pattern = args[0] || '';
        const XHR = root.XMLHttpRequest;
        if (!XHR || !XHR.prototype || !XHR.prototype.open) return;
        const open = XHR.prototype.open;
        const send = XHR.prototype.send;
        XHR.prototype.open = function (method, url) {
          if (!pattern || String(url).indexOf(pattern) >= 0) { this.__rgBlocked = true; return; }
          return open.apply(this, arguments);
        };
        if (send) XHR.prototype.send = function () { if (this.__rgBlocked) return; return send.apply(this, arguments); };
      } else if (name === 'json-prune') {
        const keys = String(args[0] || '').split(/[ |]/).filter(Boolean);
        const needle = args[1] || '';
        if (!keys.length) return;
        if (needle) { installJSONPrune(root, keys, needle); return; }
        const json = root.JSON;
        if (!json || typeof json.parse !== 'function') return;
        const original = json.parse;
        json.parse = function () {
          const value = original.apply(this, arguments);
          pruneKeys(value, keys);
          return value;
        };
      }
    });
  }
  function applyCSP(rules) {
    const doc = root.document;
    if (!doc || typeof doc.createElement !== 'function') return;
    const host = (root.location && root.location.hostname) || '';
    (rules || []).forEach(rule => {
      const domains = rule.domains || [];
      if (domains.length && !domains.some(domain => hostMatches(host, domain))) return;
      if (!rule.policy) return;
      const meta = doc.createElement('meta');
      if (meta) { meta.httpEquiv = 'Content-Security-Policy'; meta.content = rule.policy; }
      const parent = doc.head || doc.documentElement;
      if (parent && parent.appendChild && meta) parent.appendChild(meta);
    });
  }
  function rewriteText(text, rules, url) {
    let output = String(text == null ? '' : text);
    (rules || []).forEach(rule => {
      if (!rule || !rule.regex) return;
      if (rule.needle && String(url || '').indexOf(rule.needle) < 0) return;
      try { output = output.replace(new RegExp(rule.regex, rule.flags || 'g'), rule.replacement == null ? '' : String(rule.replacement)); } catch (error) {}
    });
    return output;
  }
  function installReplaceHook(rules) {
    const targets = [root];
    if (root.window && root.window !== root) targets.push(root.window);
    targets.forEach(win => installReplaceOn(win, rules));
  }
  function installReplaceOn(win, rules) {
    if (!win) return;
    win.__rgReplaceRules = rules || [];
    if (win.__rgReplaceHook) return;
    win.__rgReplaceHook = true;
    if (typeof win.fetch === 'function') {
      const original = win.fetch;
      win.fetch = function (input) {
        const url = typeof input === 'string' ? input : (input && input.url) || '';
        const pending = original.apply(this, arguments);
        if (!pending || typeof pending.then !== 'function') return pending;
        return pending.then(response => {
          const type = response && response.headers && response.headers.get && response.headers.get('content-type') || '';
          if (/^(image|audio|video|font)\//i.test(type) || /octet-stream/i.test(type)) return response;
          if (!response || typeof response.text !== 'function' || typeof root.Response !== 'function') {
            if (response && typeof response.text === 'function') {
              return response.text().then(text => ({ status: response.status || 200, headers: response.headers, text: () => Promise.resolve(rewriteText(text, win.__rgReplaceRules, url)) }));
            }
            return response;
          }
          return response.text().then(text => new root.Response(rewriteText(text, win.__rgReplaceRules, url), { status: response.status || 200, headers: response.headers }));
        });
      };
    }
    const XHR = win.XMLHttpRequest;
    if (XHR && XHR.prototype && XHR.prototype.send && XHR.prototype.open) {
      const open = XHR.prototype.open;
      const send = XHR.prototype.send;
      XHR.prototype.open = function (method, url) { this.__rgURL = url; return open.apply(this, arguments); };
      XHR.prototype.send = function () {
        this.addEventListener && this.addEventListener('readystatechange', () => {
          if (this.readyState !== 4 || this.__rgRewritten) return;
          const type = this.getResponseHeader ? (this.getResponseHeader('content-type') || '') : '';
          if (/^(image|audio|video|font)\//i.test(type)) return;
          const raw = this.responseText;
          if (typeof raw !== 'string') return;
          const next = rewriteText(raw, win.__rgReplaceRules, this.__rgURL || '');
          if (next === raw) return;
          this.__rgRewritten = true;
          try { Object.defineProperty(this, 'responseText', { configurable: true, get() { return next; } }); } catch (error) {}
        });
        return send.apply(this, arguments);
      };
    }
  }
  function applyReplace(rules, href) {
    installReplaceHook(rules);
    const list = rules || [];
    const doc = root.document;
    if (!doc || !doc.documentElement || !list.length) return false;
    const current = doc.documentElement.outerHTML;
    if (typeof current !== 'string') return false;
    const next = rewriteText(current, list, href || (root.location && root.location.href) || '');
    if (next === current) return false;
    doc.documentElement.outerHTML = next;
    return true;
  }
  function applyBlocking(globalCSS, hostMap, procedural) {
    const host = (root.location && root.location.hostname) || '';
    let extra = '';
    const map = hostMap || {};
    Object.keys(map).forEach(domain => {
      if (domain === '*' || hostMatches(host, domain)) extra += map[domain];
    });
    ensureStyle('rikugan-cosmetic', (globalCSS || '') + extra);
    const doc = root.document;
    root.__rgBlockArgs = [globalCSS, hostMap, procedural];
    if (!doc || !doc.querySelectorAll) return;
    (procedural || []).forEach(rule => {
      const domains = rule.domains || [];
      if (domains.length && !domains.some(domain => hostMatches(host, domain))) return;
      applyProcedural(doc, rule);
    });
    if (!root.__rgBlockWatch && doc.body && typeof root.MutationObserver === 'function') {
      let timer = 0;
      root.__rgBlockWatch = new root.MutationObserver(() => {
        if (timer) root.clearTimeout(timer);
        timer = root.setTimeout(() => {
          const args = root.__rgBlockArgs || [];
          applyBlocking(args[0], args[1], args[2]);
        }, 60);
      });
      root.__rgBlockWatch.observe(doc.body, { subtree: true, childList: true });
    }
  }
  function textNodes(rootNode) {
    const doc = root.document;
    if (!doc || !rootNode || !doc.createTreeWalker) return [];
    const walker = doc.createTreeWalker(rootNode, 4);
    const nodes = [];
    let node = walker.nextNode();
    while (node) { nodes.push(node); node = walker.nextNode(); }
    return nodes;
  }
  function visibleText(node) {
    const parent = node.parentElement || node.parentNode;
    if (!parent || !parent.tagName) return '';
    const tag = parent.tagName;
    if (['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEXTAREA'].indexOf(tag) >= 0) return '';
    return String(node.nodeValue || '').replace(/\s+/g, ' ').trim();
  }
  function remember(node, id) {
    root.__rgTextNodes = root.__rgTextNodes || {};
    root.__rgTextNodes[id] = node;
    node.__rgid = id;
  }
  function collectTexts(limit) {
    const body = root.document && root.document.body;
    const items = [];
    const maxNodes = limit > 0 ? limit : 100000;
    textNodes(body).forEach(node => {
      if (Object.keys(root.__rgTextNodes || {}).length >= maxNodes) return;
      const text = visibleText(node);
      if (text.length < 2 || node.__rgid) return;
      const id = 't' + (root.__rgSeq = (root.__rgSeq || 0) + 1);
      remember(node, id);
      const size = 800;
      for (let start = 0, piece = 0; start < text.length && piece < 40; start += size, piece += 1) {
        items.push({ id: id + '.' + piece, text: text.slice(start, start + size) });
      }
    });
    return items;
  }
  function applyTexts(pairs) {
    const grouped = {};
    (pairs || []).forEach(pair => {
      const base = String(pair.id || '').split('.')[0];
      if (!base) return;
      (grouped[base] = grouped[base] || []).push(pair);
    });
    Object.keys(grouped).forEach(base => {
      const node = root.__rgTextNodes && root.__rgTextNodes[base];
      if (!node) return;
      if (node.__rgOriginal == null) node.__rgOriginal = node.nodeValue;
      grouped[base].sort((a, b) => String(a.id).localeCompare(String(b.id), undefined, { numeric: true }));
      node.nodeValue = grouped[base].map(pair => pair.text).join('');
    });
    return true;
  }
  function restoreTexts() {
    const map = root.__rgTextNodes || {};
    Object.keys(map).forEach(id => {
      const node = map[id];
      if (node && node.__rgOriginal != null) node.nodeValue = node.__rgOriginal;
    });
    return true;
  }
  function watchNewText(ms) {
    const doc = root.document;
    if (!doc || !doc.body || typeof root.MutationObserver !== 'function') return false;
    if (root.__rgWatch) root.__rgWatch.disconnect();
    const bounded = ms > 0;
    const until = Date.now() + ms;
    const observer = new root.MutationObserver(() => {
      if (bounded && Date.now() > until) { observer.disconnect(); return; }
      const items = collectTexts(0);
      if (!items.length || !root.webkit || !webkit.messageHandlers || !webkit.messageHandlers.rikuganPage) return;
      webkit.messageHandlers.rikuganPage.postMessage({ action: 'texts', items: items.slice(0, 200) });
    });
    root.__rgWatch = observer;
    observer.observe(doc.body, { subtree: true, childList: true, characterData: true });
    return true;
  }
  function stopWatch() {
    if (root.__rgWatch) { root.__rgWatch.disconnect(); root.__rgWatch = null; }
  }
  function blockFrom(node) {
    if (!node || node.nodeType !== 1) return null;
    const tag = String(node.tagName || '').toLowerCase();
    if (['script', 'style', 'noscript', 'svg', 'form', 'nav', 'footer', 'iframe'].indexOf(tag) >= 0) return null;
    if (tag === 'img') {
      const src = node.currentSrc || node.src || '';
      return src ? { tag: 'img', text: node.alt || '', src: src, href: '' } : null;
    }
    if (/^h[1-6]$/.test(tag) || tag === 'p' || tag === 'li' || tag === 'blockquote' || tag === 'pre' || tag === 'figcaption') {
      const text = String(node.innerText || node.textContent || '').replace(/\s+/g, ' ').trim();
      if (!text) return null;
      const link = node.querySelector ? node.querySelector('a[href]') : null;
      return { tag: tag, text: text, src: '', href: link ? (link.href || '') : '' };
    }
    return null;
  }
  function extractArticle() {
    const doc = root.document;
    if (!doc) return null;
    const titleNode = doc.querySelector && (doc.querySelector('meta[property="og:title"]') || doc.querySelector('h1'));
    const title = (titleNode && (titleNode.content || titleNode.textContent)) || doc.title || '';
    const authorNode = doc.querySelector && doc.querySelector('meta[name="author"]');
    const author = (authorNode && authorNode.content) || '';
    const rootNode = (doc.querySelector && (doc.querySelector('article') || doc.querySelector('main'))) || doc.body;
    const blocks = [];
    const images = [];
    const walk = node => {
      if (!node || blocks.length > 2000) return;
      const block = blockFrom(node);
      if (block) {
        blocks.push(block);
        if (block.src) images.push(block.src);
        if (block.tag === 'p' || /^h[1-6]$/.test(block.tag)) return;
      }
      const children = node.children ? Array.from(node.children) : [];
      children.forEach(walk);
    };
    if (rootNode) walk(rootNode);
    const text = blocks.filter(block => block.tag !== 'img').map(block => block.text).join('\n\n');
    return { title: String(title).trim(), author: String(author).trim(), text: text, blocks: blocks, images: images.slice(0, 12) };
  }
  function kindFor(url) {
    const clean = String(url || '').split('?')[0].toLowerCase();
    if (/\.(png|jpe?g|gif|webp|avif|svg)$/.test(clean)) return 'image';
    if (/\.(mp4|webm|mov|m4v|mkv)$/.test(clean)) return 'video';
    if (/\.m3u8$/.test(clean) || clean.indexOf('.m3u8') >= 0) return 'hls';
    if (/\.mpd$/.test(clean) || clean.indexOf('.mpd') >= 0) return 'dash';
    if (/\.(mp3|m4a|aac|wav|ogg)$/.test(clean)) return 'audio';
    return '';
  }
  function collectMedia() {
    const doc = root.document;
    const found = [];
    const push = (url, kind, extra) => {
      if (!url || found.length > 300) return;
      const absolute = String(url);
      if (!/^https?:/i.test(absolute) && absolute.indexOf('blob:') !== 0) return;
      if (found.some(item => item.url === absolute)) return;
      found.push(Object.assign({ url: absolute, kind: kind || kindFor(absolute) || 'file' }, extra || {}));
    };
    if (doc && doc.querySelectorAll) {
      doc.querySelectorAll('img').forEach(img => push(img.currentSrc || img.src, 'image', { width: img.naturalWidth || 0, height: img.naturalHeight || 0 }));
      doc.querySelectorAll('video,audio,source').forEach(node => {
        const kind = (node.tagName === 'AUDIO' || (node.type || '').indexOf('audio') === 0) ? 'audio' : kindFor(node.currentSrc || node.src) || 'video';
        push(node.currentSrc || node.src, kind, { width: node.videoWidth || 0, height: node.videoHeight || 0 });
      });
    }
    (root.__rikuganNet || []).forEach(url => { const kind = kindFor(url); if (kind) push(url, kind); });
    if (root.performance && performance.getEntriesByType) {
      ['resource', 'navigation'].forEach(type => {
        performance.getEntriesByType(type).forEach(entry => {
          const kind = kindFor(entry.name);
          if (kind) push(entry.name, kind, { size: entry.transferSize || entry.decodedBodySize || 0 });
        });
      });
    }
    return found;
  }
  function resolveURL(value, base) {
    try { return new URL(value, base).href; } catch (error) { return value; }
  }
  function parseM3U8(text, base) {
    const lines = String(text || '').split(/\r?\n/);
    const variants = [];
    if (lines[0] && lines[0].indexOf('#EXTM3U') !== 0 && String(text).indexOf('#EXTM3U') < 0) return variants;
    for (let index = 0; index < lines.length; index += 1) {
      const line = lines[index].trim();
      if (line.indexOf('#EXT-X-STREAM-INF:') === 0) {
        const bandwidth = /BANDWIDTH=(\d+)/.exec(line);
        const resolution = /RESOLUTION=(\d+)x(\d+)/.exec(line);
        const codecs = /CODECS="([^"]*)"/.exec(line);
        const next = (lines[index + 1] || '').trim();
        if (next && next[0] !== '#') {
          variants.push({
            url: resolveURL(next, base),
            bandwidth: bandwidth ? Number(bandwidth[1]) : 0,
            width: resolution ? Number(resolution[1]) : 0,
            height: resolution ? Number(resolution[2]) : 0,
            codecs: codecs ? codecs[1] : '',
            kind: 'hls'
          });
          index += 1;
        }
      } else if (line && line[0] !== '#' && /\.(mp4|m4s|ts|aac|m3u8)(\?|$)/i.test(line)) {
        variants.push({ url: resolveURL(line, base), bandwidth: 0, width: 0, height: 0, codecs: '', kind: 'hls' });
      }
    }
    return variants;
  }
  function parseMPD(text, base) {
    const body = String(text || '');
    if (body.indexOf('<MPD') < 0 && body.indexOf('<mpd') < 0) return [];
    const variants = [];
    const reps = body.match(/<Representation\b[^>]*>[\s\S]*?<\/Representation>/gi) || [];
    reps.forEach(block => {
      const bandwidth = /bandwidth="(\d+)"/i.exec(block);
      const width = /width="(\d+)"/i.exec(block);
      const height = /height="(\d+)"/i.exec(block);
      const baseURL = /<BaseURL>([^<]+)<\/BaseURL>/i.exec(block);
      if (!baseURL) return;
      variants.push({
        url: resolveURL(baseURL[1].trim(), base),
        bandwidth: bandwidth ? Number(bandwidth[1]) : 0,
        width: width ? Number(width[1]) : 0,
        height: height ? Number(height[1]) : 0,
        codecs: '',
        kind: 'dash'
      });
    });
    return variants;
  }
  function installNetHook() {
    if (root.__rikuganNet || !root.window) return;
    const urls = [];
    root.__rikuganNet = urls;
    const push = url => { try { if (url && urls.length < 300) urls.push(String(url)); } catch (error) {} };
    const win = root.window;
    if (typeof win.fetch === 'function') {
      const original = win.fetch;
      win.fetch = function (input) {
        try { push(typeof input === 'string' ? input : input && input.url); } catch (error) {}
        return original.apply(this, arguments);
      };
    }
    const open = win.XMLHttpRequest && win.XMLHttpRequest.prototype && win.XMLHttpRequest.prototype.open;
    if (open) {
      win.XMLHttpRequest.prototype.open = function (method, url) { push(url); return open.apply(this, arguments); };
    }
  }
  function post(message) {
    try {
      if (root.webkit && webkit.messageHandlers && webkit.messageHandlers.rikuganPage) webkit.messageHandlers.rikuganPage.postMessage(message);
    } catch (error) {}
  }
  function installConsole() {
    if (root.__rgConsole) return;
    root.__rgConsole = true;
    const send = (level, text) => post({ action: 'console', level: level, text: String(text).slice(0, 2000) });
    if (typeof root.addEventListener === 'function') {
      root.addEventListener('error', event => send('error', (event && event.message || 'error') + ' @ ' + (event && event.filename || '') + ':' + (event && event.lineno || '')));
      root.addEventListener('unhandledrejection', event => send('error', 'Unhandled rejection: ' + (event && event.reason && event.reason.message || event && event.reason || '')));
    }
    if (root.console && !root.console.__rgWrapped) {
      ['log', 'info', 'warn', 'error'].forEach(level => {
        const original = root.console[level];
        root.console[level] = function () {
          send(level, Array.from(arguments).map(item => {
            try { return typeof item === 'string' ? item : JSON.stringify(item); } catch (error) { return String(item); }
          }).join(' '));
          if (typeof original === 'function') return original.apply(this, arguments);
        };
      });
      root.console.__rgWrapped = true;
    }
  }
  function installNotifications(decision) {
    const mode = decision || 'ask';
    root.__rgNotifyMode = mode === 'allow' ? 'granted' : mode === 'block' ? 'denied' : 'default';
    function RikuganNotification(title, options) {
      const current = root.__rgNotifyMode || 'default';
      if (current === 'denied') throw new Error('Notification permission denied');
      const payload = { action: 'show-notification', title: String(title || ''), body: String((options && options.body) || '') };
      if (current === 'granted') { post(payload); return; }
      const id = 'n' + Math.random().toString(36).slice(2);
      root.__rgNotify = root.__rgNotify || {};
      root.__rgNotify[id] = decisionName => {
        root.__rgNotifyMode = decisionName;
        if (decisionName === 'granted') post(payload);
      };
      post({ action: 'notification', id: id });
    }
    RikuganNotification.permission = root.__rgNotifyMode;
    RikuganNotification.requestPermission = () => new Promise(resolve => {
      if (root.__rgNotifyMode === 'granted' || root.__rgNotifyMode === 'denied') { resolve(root.__rgNotifyMode); return; }
      const id = 'n' + Math.random().toString(36).slice(2);
      root.__rgNotify = root.__rgNotify || {};
      root.__rgNotify[id] = decisionName => { root.__rgNotifyMode = decisionName; RikuganNotification.permission = decisionName; resolve(decisionName); };
      post({ action: 'notification', id: id });
    });
    root.Notification = RikuganNotification;
    return true;
  }
  function startPicker() {
    const doc = root.document;
    if (!doc || !doc.body || doc.getElementById('rikugan-picker')) return false;
    const veil = doc.createElement('div');
    veil.id = 'rikugan-picker';
    veil.style.cssText = 'position:fixed;inset:0;z-index:2147483646;cursor:crosshair;background:rgba(20,40,80,.05)';
    const tip = doc.createElement('div');
    tip.style.cssText = 'position:fixed;left:12px;right:12px;bottom:12px;z-index:2147483647;background:#111;color:#fff;padding:12px 14px;border-radius:12px;font:14px system-ui';
    tip.textContent = '点选要隐藏的元素';
    let current = null;
    const highlight = event => {
      veil.style.pointerEvents = 'none';
      const target = doc.elementFromPoint(event.clientX, event.clientY);
      veil.style.pointerEvents = 'auto';
      if (!target || target === veil || target === tip) return;
      if (current && current.style) current.style.outline = current.__rgOutline || '';
      current = target;
      if (current.style) {
        current.__rgOutline = target.style.outline;
        target.style.outline = '2px solid #ff5a36';
      }
    };
    veil.addEventListener('mousemove', highlight);
    veil.addEventListener('touchmove', highlight);
    const finish = event => {
      if (event) event.preventDefault();
      const chosen = current;
      veil.remove(); tip.remove();
      if (chosen && chosen.style) chosen.style.outline = chosen.__rgOutline || '';
      if (!chosen) return;
      post({ action: 'picker', selector: selector(chosen), label: (chosen.tagName || '').toLowerCase() });
    };
    veil.addEventListener('click', finish);
    doc.body.append(veil, tip);
    return true;
  }
  function countMatches(query) {
    const doc = root.document;
    if (!doc || !doc.body || !query) return 0;
    const needle = String(query).toLowerCase();
    let total = 0;
    textNodes(doc.body).forEach(node => {
      const value = String(node.nodeValue || '').toLowerCase();
      let cursor = 0;
      while (cursor < value.length) {
        const at = value.indexOf(needle, cursor);
        if (at < 0) break;
        total += 1;
        cursor = at + needle.length;
      }
    });
    return total;
  }
  function clearFind() {
    const doc = root.document;
    if (!doc) return { index: 0, total: 0 };
    if (doc.querySelectorAll) {
      doc.querySelectorAll('mark[data-rikugan-find]').forEach(mark => {
        const text = doc.createTextNode(mark.textContent || '');
        if (mark.replaceWith) mark.replaceWith(text);
      });
    }
    if (doc.body && doc.body.normalize) doc.body.normalize();
    return { index: 0, total: 0 };
  }
  function videoAction(action) {
    const video = root.document && root.document.querySelector && root.document.querySelector('video');
    if (!video) return 'no-video';
    try {
      if (action === 'pip' && video.webkitSetPresentationMode) { video.webkitSetPresentationMode(video.webkitPresentationMode === 'picture-in-picture' ? 'inline' : 'picture-in-picture'); return 'ok'; }
      if (action === 'pip' && video.requestPictureInPicture) { video.requestPictureInPicture(); return 'ok'; }
      if (action === 'fullscreen' && video.webkitEnterFullscreen) { video.webkitEnterFullscreen(); return 'ok'; }
      if (action === 'fullscreen' && video.requestFullscreen) { video.requestFullscreen(); return 'ok'; }
      if (action === 'airplay' && video.webkitShowPlaybackTargetPicker) { video.webkitShowPlaybackTargetPicker(); return 'ok'; }
    } catch (error) { return String(error); }
    return 'unsupported';
  }
  function fill(values) {
    const doc = root.document;
    if (!doc || !doc.querySelector) return {};
    const set = (input, value) => {
      if (!input || value == null || value === '') return false;
      if (input.focus) input.focus();
      input.value = value;
      if (input.dispatchEvent && typeof root.Event === 'function') {
        input.dispatchEvent(new root.Event('input', { bubbles: true }));
        input.dispatchEvent(new root.Event('change', { bubbles: true }));
      }
      return true;
    };
    const one = selectorText => doc.querySelector(selectorText);
    return {
      username: set(one('input[autocomplete="username"],input[type="email"],input[name*="user" i],input[name*="email" i]'), values.username),
      password: set(one('input[type="password"]'), values.password),
      name: set(one('input[autocomplete="name"],input[name="name" i]'), values.name),
      email: set(one('input[autocomplete="email"],input[type="email"],input[name*="email" i]'), values.email),
      phone: set(one('input[autocomplete="tel"],input[type="tel"],input[name*="phone" i],input[name*="tel" i]'), values.phone),
      address: set(one('textarea[autocomplete="street-address"],input[autocomplete="street-address"],textarea[name*="address" i],input[name*="address" i]'), values.address),
      paymentLast4: set(one('input[autocomplete="cc-number"],input[name*="card" i],input[name*="cc" i]'), values.cardNumber || values.paymentLast4)
    };
  }
  const api = {
    selector, setAppearance, setFont, fontOverrideCSS, darkCSS: darkRules, applyBlocking, applyScriptlets, applyCSP, applyReplace, collectTexts, applyTexts, restoreTexts,
    watchNewText, stopWatch, extractArticle, collectMedia, parseM3U8, parseMPD, installNetHook, installConsole, installNotifications,
    startPicker, countMatches, clearFind, videoAction, fill, ensureStyle, insertExtensionCSS, installClipboard, installExtensionRelay
  };
  root.RikuganPageTools = api;
  try { installNetHook(); } catch (error) {}
  try { installConsole(); } catch (error) {}
})(typeof globalThis !== 'undefined' ? globalThis : this);
