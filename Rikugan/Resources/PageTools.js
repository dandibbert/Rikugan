(function (root) {
  'use strict';
  function cssEscape(value) {
    return String(value).replace(/[^A-Za-z0-9_-]/g, ch => '\\' + ch);
  }
  function classTokens(el) {
    if (!el || !el.classList) return [];
    return Array.from(el.classList).filter(name => /^[A-Za-z_-][\w-]*$/.test(name)).slice(0, 2);
  }
  function selector(el) {
    if (!el || el.nodeType !== 1) return '';
    if (el.id && /^[A-Za-z][\w:.-]*$/.test(el.id)) return '#' + cssEscape(el.id);
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
  const darkCSS = 'html{background:#fff!important;filter:invert(1) hue-rotate(180deg)!important}img,video,picture,canvas,iframe,svg{filter:invert(1) hue-rotate(180deg)!important}';
  function setAppearance(mode) {
    if (mode === 'on') ensureStyle('rikugan-dark', darkCSS);
    else if (mode === 'auto') ensureStyle('rikugan-dark', '@media (prefers-color-scheme: dark){' + darkCSS + '}');
    else ensureStyle('rikugan-dark', '');
  }
  function setFont(family, faceCSS) {
    ensureStyle('rikugan-font', '');
    if (root.RikuganWebFonts) root.RikuganWebFonts.apply(family, faceCSS);
  }
  function textNodes(rootNode) {
    const doc = root.document;
    if (!doc || !rootNode) return [];
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
  function collectTexts(limit) {
    const body = root.document && root.document.body;
    const items = [];
    textNodes(body).forEach(node => {
      if (items.length >= (limit || 80)) return;
      const text = visibleText(node);
      if (text.length < 2) return;
      const id = 't' + items.length;
      node.__rgid = id;
      items.push({ id: id, text: text.slice(0, 400) });
    });
    root.__rgTextNodes = root.__rgTextNodes || {};
    items.forEach(item => {
      textNodes(body).forEach(node => { if (node.__rgid === item.id) root.__rgTextNodes[item.id] = node; });
    });
    return items;
  }
  function applyTexts(pairs) {
    (pairs || []).forEach(pair => {
      const node = root.__rgTextNodes && root.__rgTextNodes[pair.id];
      if (!node) return;
      if (node.__rgOriginal == null) node.__rgOriginal = node.nodeValue;
      node.nodeValue = pair.text;
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
  function extractArticle() {
    const doc = root.document;
    if (!doc) return null;
    const title = (doc.querySelector('meta[property="og:title"]') || {}).content || (doc.querySelector('h1') || {}).textContent || doc.title || '';
    const author = (doc.querySelector('meta[name="author"]') || {}).content || '';
    const rootNode = doc.querySelector('article') || doc.querySelector('main') || doc.body;
    const images = Array.from((rootNode || doc).querySelectorAll ? (rootNode || doc).querySelectorAll('img') : []).slice(0, 12).map(img => img.currentSrc || img.src).filter(Boolean);
    return { title: String(title).trim(), author: String(author).trim(), text: rootNode ? (rootNode.innerText || rootNode.textContent || '') : '', images: images };
  }
  function collectMedia() {
    const doc = root.document;
    const found = [];
    const push = (url, kind, extra) => {
      if (!url || found.length > 300) return;
      const absolute = String(url);
      if (found.some(item => item.url === absolute)) return;
      found.push(Object.assign({ url: absolute, kind: kind || 'file' }, extra || {}));
    };
    if (doc) {
      doc.querySelectorAll('img').forEach(img => push(img.currentSrc || img.src, 'image', { width: img.naturalWidth || 0, height: img.naturalHeight || 0 }));
      doc.querySelectorAll('video,audio,source').forEach(node => {
        const kind = (node.tagName === 'AUDIO' || (node.type || '').indexOf('audio') === 0) ? 'audio' : 'video';
        push(node.currentSrc || node.src, kind);
      });
    }
    (root.__rikuganNet || []).forEach(url => {
      const clean = String(url).split('?')[0].toLowerCase();
      const kind = /\.(png|jpe?g|gif|webp|avif|svg)$/.test(clean) ? 'image' : /\.(mp4|webm|mov|m4v|mkv)$/.test(clean) || clean.indexOf('.m3u8') >= 0 ? 'video' : /\.(mp3|m4a|aac|wav|ogg)$/.test(clean) ? 'audio' : '';
      if (kind) push(url, kind);
    });
    if (root.performance && performance.getEntriesByType) {
      performance.getEntriesByType('resource').forEach(entry => {
        const clean = String(entry.name).split('?')[0].toLowerCase();
        const kind = /\.(png|jpe?g|gif|webp|avif|svg)$/.test(clean) ? 'image' : /\.(mp4|webm|mov|m4v|mkv|m3u8)$/.test(clean) ? 'video' : /\.(mp3|m4a|aac|wav|ogg)$/.test(clean) ? 'audio' : '';
        if (kind) push(entry.name, kind, { size: entry.transferSize || 0 });
      });
    }
    return found;
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
      if (current) current.style.outline = current.__rgOutline || '';
      current = target;
      current.__rgOutline = target.style.outline;
      target.style.outline = '2px solid #ff5a36';
    };
    veil.addEventListener('mousemove', highlight);
    veil.addEventListener('touchmove', highlight);
    const finish = event => {
      if (event) event.preventDefault();
      const chosen = current;
      veil.remove(); tip.remove();
      if (chosen) chosen.style.outline = chosen.__rgOutline || '';
      if (!chosen || !root.webkit || !webkit.messageHandlers || !webkit.messageHandlers.rikuganPage) return;
      webkit.messageHandlers.rikuganPage.postMessage({ action: 'picker', selector: selector(chosen), label: chosen.tagName.toLowerCase() });
    };
    veil.addEventListener('click', finish);
    doc.body.append(veil, tip);
    return true;
  }
  function clearFind() {
    const doc = root.document;
    if (!doc) return { index: 0, total: 0 };
    doc.querySelectorAll('mark[data-rikugan-find]').forEach(mark => {
      const text = doc.createTextNode(mark.textContent || '');
      mark.replaceWith(text);
    });
    doc.body && doc.body.normalize && doc.body.normalize();
    return { index: 0, total: 0 };
  }
  function find(query, direction) {
    const doc = root.document;
    if (!doc || !doc.body) return { index: 0, total: 0 };
    const needle = String(query || '');
    if (!needle) return clearFind();
    if (!doc.querySelector('mark[data-rikugan-find]')) {
      const flags = needle.toLowerCase();
      textNodes(doc.body).forEach(node => {
        const value = node.nodeValue || '';
        const lower = value.toLowerCase();
        if (!lower.includes(flags)) return;
        const fragment = doc.createDocumentFragment();
        let cursor = 0;
        while (cursor < value.length) {
          const at = lower.indexOf(flags, cursor);
          if (at < 0) { fragment.append(value.slice(cursor)); break; }
          if (at > cursor) fragment.append(value.slice(cursor, at));
          const mark = doc.createElement('mark');
          mark.dataset.rikuganFind = '1';
          mark.style.background = '#ffe08a';
          mark.style.color = '#1a1a1a';
          mark.textContent = value.slice(at, at + needle.length);
          fragment.append(mark);
          cursor = at + needle.length;
        }
        node.parentNode.replaceChild(fragment, node);
      });
    }
    const marks = Array.from(doc.querySelectorAll('mark[data-rikugan-find]'));
    if (!marks.length) return { index: 0, total: 0 };
    let current = marks.findIndex(mark => mark.dataset.rikuganCurrent === '1');
    if (current >= 0) delete marks[current].dataset.rikuganCurrent;
    const step = direction < 0 ? -1 : 1;
    current = current < 0 ? 0 : (current + step + marks.length) % marks.length;
    marks[current].dataset.rikuganCurrent = '1';
    marks[current].style.outline = '2px solid #d97706';
    marks.forEach((mark, index) => { if (index !== current) mark.style.outline = ''; });
    marks[current].scrollIntoView({ block: 'center', inline: 'nearest' });
    return { index: current + 1, total: marks.length };
  }
  function videoAction(action) {
    const video = root.document && root.document.querySelector('video');
    if (!video) return 'no-video';
    try {
      if (action === 'pip' && video.webkitSetPresentationMode) { video.webkitSetPresentationMode(video.webkitPresentationMode === 'picture-in-picture' ? 'inline' : 'picture-in-picture'); return 'ok'; }
      if (action === 'pip' && video.requestPictureInPicture) { video.requestPictureInPicture(); return 'ok'; }
      if (action === 'fullscreen' && video.webkitEnterFullscreen) { video.webkitEnterFullscreen(); return 'ok'; }
      if (action === 'airplay' && video.webkitShowPlaybackTargetPicker) { video.webkitShowPlaybackTargetPicker(); return 'ok'; }
    } catch (error) { return String(error); }
    return 'unsupported';
  }
  function fill(values) {
    const doc = root.document;
    if (!doc) return {};
    const set = (input, value) => {
      if (!input || value == null) return false;
      input.focus();
      input.value = value;
      input.dispatchEvent(new Event('input', { bubbles: true }));
      input.dispatchEvent(new Event('change', { bubbles: true }));
      return true;
    };
    const username = doc.querySelector('input[autocomplete="username"],input[type="email"],input[name*="user" i],input[name*="email" i]');
    const password = doc.querySelector('input[type="password"]');
    const name = doc.querySelector('input[autocomplete="name"],input[name="name" i]');
    return {
      username: set(username, values.username),
      password: set(password, values.password),
      name: set(name, values.name)
    };
  }
  const api = { selector, setAppearance, setFont, collectTexts, applyTexts, restoreTexts, extractArticle, collectMedia, installNetHook, startPicker, find, clearFind, videoAction, fill, ensureStyle };
  root.RikuganPageTools = api;
  try { installNetHook(); } catch (error) {}
})(typeof globalThis !== 'undefined' ? globalThis : this);
