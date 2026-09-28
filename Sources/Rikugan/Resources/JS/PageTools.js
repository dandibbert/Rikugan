// Rikugan page tools. Runs in the isolated "rikugan-tools" content world of every frame.
// Provides page dark mode, web font override, cosmetic filtering, element picker, reader
// extraction, page translation, image / media scanning, video helpers and autofill.
(function (cfg) {
  'use strict';
  if (!cfg || window.__rikuganTools) return;
  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[cfg.handler];
  const post = (op, args) => (handler ? handler.postMessage({ ch: 'tools', op, args: args || {} }) : Promise.reject(new Error('bridge unavailable')));
  const isTop = (() => { try { return window.top === window; } catch (_) { return false; } })();

  // ---- Style sheet management (adoptedStyleSheets are not subject to page CSP) ---------------------
  const sheets = {};
  const whenRoot = (fn) => {
    if (document.documentElement) return fn();
    const obs = new MutationObserver(() => { if (document.documentElement) { obs.disconnect(); fn(); } });
    obs.observe(document, { childList: true });
  };
  const setSheet = (name, cssText) => {
    whenRoot(() => {
      try {
        let sheet = sheets[name];
        if (!sheet) {
          sheet = new CSSStyleSheet();
          sheets[name] = sheet;
          document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
        } else if (!document.adoptedStyleSheets.includes(sheet)) {
          document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
        }
        sheet.replaceSync(cssText || '');
      } catch (e) {
        let style = document.getElementById('rikugan-style-' + name);
        if (!style) { style = document.createElement('style'); style.id = 'rikugan-style-' + name; (document.head || document.documentElement).appendChild(style); }
        style.textContent = cssText || '';
      }
    });
  };
  // Insert many selectors defensively: one invalid selector must not disable the whole group.
  const selectorsToCSS = (selectors) => {
    const valid = [];
    const test = (s) => { try { document.createDocumentFragment().querySelector(s); return true; } catch (_) { return false; } };
    for (let i = 0; i < selectors.length; i += 60) {
      const group = selectors.slice(i, i + 60);
      if (test(group.join(','))) valid.push(group.join(',\n'));
      else for (const s of group) if (test(s)) valid.push(s);
    }
    return valid.map((g) => g + ' { display: none !important; }').join('\n');
  };

  // ---- Dark mode ------------------------------------------------------------------------------
  let darkOptions = null;
  const luminance = (color) => {
    const m = /rgba?\(([^)]+)\)/.exec(color || '');
    if (!m) return null;
    const p = m[1].split(',').map((x) => parseFloat(x));
    if (p.length === 4 && p[3] === 0) return null;
    const c = p.slice(0, 3).map((v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); });
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
  };
  const pageIsAlreadyDark = () => {
    try {
      const meta = document.querySelector('meta[name="color-scheme"]');
      const bodyBg = document.body ? getComputedStyle(document.body).backgroundColor : null;
      const htmlBg = getComputedStyle(document.documentElement).backgroundColor;
      const l = luminance(bodyBg) ?? luminance(htmlBg);
      if (l !== null) return l < 0.2;
      if (meta && /^\s*dark\s*$/i.test(meta.content)) return true;
      return false;
    } catch (_) { return false; }
  };
  const darkCSS = (o) => {
    const b = (o.brightness || 100) / 100, c = (o.contrast || 100) / 100;
    return `html { filter: invert(0.93) hue-rotate(180deg) brightness(${b}) contrast(${c}) !important; background-color: #fff !important; }
img, video, picture, canvas, iframe, embed, object, svg image, [style*="background-image"], [data-rikugan-noinvert] { filter: invert(1) hue-rotate(180deg) !important; }
picture img, picture video { filter: none !important; }
html::-webkit-scrollbar { background: #222; }`;
  };
  const applyDarkMode = (o) => {
    darkOptions = o && o.enabled ? o : null;
    if (!darkOptions) { setSheet('dark', ''); return; }
    setSheet('dark', darkCSS(darkOptions));
    const verify = () => {
      if (!darkOptions) return;
      setSheet('dark', '');
      const dark = pageIsAlreadyDark();
      setSheet('dark', dark ? '' : darkCSS(darkOptions));
    };
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', verify, { once: true });
    else verify();
  };

  // ---- Web font override (icon-font safe) ---------------------------------------------------------
  // Instead of `* { font-family: X !important }`, text-bearing elements are classified once
  // (body / heading / mono) from their *own* computed font before any override applies. Elements
  // using icon / symbol fonts (Material Icons, Font Awesome, the page's own PUA icon fonts …) are
  // never tagged, so their glyphs keep rendering.
  const loadedFonts = new Set();
  let fontPlan = null, fontObserver = null, fontQueue = [], fontScheduled = false, fontTagged = 0;
  const iconClass = /(^|\s)(fa|fas|far|fab|fal|fad|fa-[\w-]+|material-icons[\w-]*|material-symbols[\w-]*|glyphicon[\w-]*|bi|bi-[\w-]+|octicon[\w-]*|icon|icons|iconfont|dashicons[\w-]*|ti|ti-[\w-]+|ri-[\w-]+|codicon[\w-]*)(\s|$)/i;
  const monoFamily = /mono|courier|consolas|menlo|monaco|source code|fira code|jetbrains/i;
  const puaRe = /[-]|[\uDB80-\uDBFF][\uDC00-\uDFFF]/;
  const skipTagsFont = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'SVG', 'MATH', 'TEMPLATE', 'IFRAME', 'CANVAS', 'VIDEO', 'AUDIO', 'IMG', 'HTML', 'HEAD']);
  const ownText = (el) => {
    let t = '';
    for (const n of el.childNodes) if (n.nodeType === 3) t += n.nodeValue;
    return t.trim();
  };
  const fontRole = (el) => {
    if (skipTagsFont.has(el.tagName) || el.closest('svg, math')) return null;
    const isField = ['INPUT', 'TEXTAREA', 'SELECT', 'BUTTON'].includes(el.tagName);
    const text = isField ? 'x' : ownText(el);
    if (!text) return null;
    const cls = typeof el.className === 'string' ? el.className : '';
    if (iconClass.test(cls) || puaRe.test(text) || el.getAttribute('aria-hidden') === 'true' && text.length <= 3) return 'icon';
    let family = '';
    try { family = getComputedStyle(el).fontFamily || ''; } catch (_) {}
    const primary = family.split(',')[0].replace(/["']/g, '').trim();
    if (fontPlan.iconRe.test(primary)) return 'icon';
    if (/^(CODE|PRE|KBD|SAMP|TT)$/.test(el.tagName) || el.closest('pre, code, kbd, samp') || monoFamily.test(primary) || /^monospace$/i.test(primary)) return 'mono';
    if (/^H[1-6]$/.test(el.tagName) || el.closest('h1, h2, h3, h4, h5, h6')) return 'heading';
    return 'body';
  };
  const tagElement = (el) => {
    if (el.nodeType !== 1 || el.hasAttribute('data-rk-font') || el.hasAttribute('data-rk-font-skip')) return;
    const role = fontRole(el);
    if (!role) return;
    if (role === 'icon' || !fontPlan[role]) { el.setAttribute('data-rk-font-skip', role); return; }
    el.setAttribute('data-rk-font', role);
    fontTagged++;
  };
  const drainFontQueue = () => {
    fontScheduled = false;
    if (!fontPlan) return;
    const deadline = performance.now() + 12;
    while (fontQueue.length && performance.now() < deadline) {
      const root = fontQueue.shift();
      if (!root || !root.isConnected) continue;
      if (root.nodeType === 1) tagElement(root);
      if (root.querySelectorAll) {
        const all = root.querySelectorAll('*');
        if (all.length > 400) { for (let i = 0; i < all.length; i += 400) fontQueue.push({ isConnected: true, nodeType: 0, querySelectorAll: () => Array.prototype.slice.call(all, i, i + 400) }); continue; }
        for (const el of all) tagElement(el);
      }
    }
    if (fontQueue.length) scheduleFontWork();
  };
  const scheduleFontWork = () => {
    if (fontScheduled) return;
    fontScheduled = true;
    (window.requestIdleCallback || ((f) => setTimeout(f, 16)))(drainFontQueue, { timeout: 200 });
  };
  const fontStack = (family) => '"' + String(family).replace(/"/g, '') + '", "Apple Color Emoji", -apple-system, system-ui, sans-serif';
  const applyFont = async (o) => {
    if (fontObserver) { fontObserver.disconnect(); fontObserver = null; }
    document.querySelectorAll('[data-rk-font],[data-rk-font-skip]').forEach((el) => { el.removeAttribute('data-rk-font'); el.removeAttribute('data-rk-font-skip'); });
    fontTagged = 0;
    if (!o || !(o.body || o.heading || o.mono)) { fontPlan = null; setSheet('font', ''); return; }
    fontPlan = { body: o.body || null, heading: o.heading || null, mono: o.mono || null, iconRe: new RegExp(o.iconPattern || 'icon', 'i') };
    for (const file of o.files || []) {
      if (loadedFonts.has(file.fileID)) continue;
      loadedFonts.add(file.fileID);
      try {
        const data = await post('fontData', { id: file.fileID });
        if (data && data.base64) {
          const bin = atob(data.base64);
          const bytes = new Uint8Array(bin.length);
          for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
          const face = new FontFace(file.family, bytes.buffer);
          await face.load();
          document.fonts.add(face);
        }
      } catch (e) { console.warn('[Rikugan] custom font load failed', file.family, e); }
    }
    const rules = [];
    if (fontPlan.body) rules.push(`[data-rk-font="body"] { font-family: ${fontStack(fontPlan.body)} !important; }`);
    if (fontPlan.heading) rules.push(`[data-rk-font="heading"] { font-family: ${fontStack(fontPlan.heading)} !important; }`);
    if (fontPlan.mono) rules.push(`[data-rk-font="mono"] { font-family: ${fontStack(fontPlan.mono).replace('sans-serif', 'monospace')} !important; }`);
    setSheet('font', rules.join('\n'));
    const start = () => {
      fontQueue.push(document.body || document.documentElement);
      scheduleFontWork();
      fontObserver = new MutationObserver((mutations) => {
        for (const m of mutations) for (const n of m.addedNodes) if (n.nodeType === 1) fontQueue.push(n); else if (n.nodeType === 3 && n.parentElement) fontQueue.push(n.parentElement);
        if (fontQueue.length) scheduleFontWork();
      });
      fontObserver.observe(document.documentElement, { childList: true, subtree: true });
    };
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, { once: true }); else start();
  };
  const fontStatus = () => ({ tagged: fontTagged, pending: fontQueue.length, plan: fontPlan ? { body: fontPlan.body, heading: fontPlan.heading, mono: fontPlan.mono } : null });

  // ---- Cosmetic filtering ---------------------------------------------------------------------------
  const applyCosmetic = (selectors, css) => {
    const text = selectorsToCSS(selectors || []) + '\n' + (css || []).join('\n');
    setSheet('cosmetic', text);
  };
  const extraHidden = [];
  const hideNow = (selector) => { extraHidden.push(selector); setSheet('picker', selectorsToCSS(extraHidden)); };

  // ---- Element picker ----------------------------------------------------------------------------
  let picker = null;
  const cssEscape = (s) => (window.CSS && CSS.escape ? CSS.escape(s) : String(s).replace(/[^a-zA-Z0-9_-]/g, (c) => '\\' + c));
  const selectorFor = (el) => {
    if (!el || el.nodeType !== 1) return null;
    const unique = (sel) => { try { return document.querySelectorAll(sel).length === 1; } catch (_) { return false; } };
    if (el.id && /^[A-Za-z][\w-]*$/.test(el.id) && !/\d{4,}/.test(el.id) && unique('#' + cssEscape(el.id))) return '#' + cssEscape(el.id);
    const parts = [];
    let cur = el;
    while (cur && cur.nodeType === 1 && cur !== document.documentElement) {
      let part = cur.tagName.toLowerCase();
      if (cur.id && /^[A-Za-z][\w-]*$/.test(cur.id) && !/\d{4,}/.test(cur.id) && cur !== el) {
        parts.unshift('#' + cssEscape(cur.id));
        const s = parts.join(' > ');
        if (unique(s)) return s;
        cur = cur.parentElement; continue;
      }
      const classes = Array.from(cur.classList).filter((c) => /^[A-Za-z_-][\w-]*$/.test(c) && !/\d{3,}/.test(c) && !/^(is|has)-(active|open|hover|visible|selected)/.test(c)).slice(0, 3);
      if (classes.length) part += '.' + classes.map(cssEscape).join('.');
      const parent = cur.parentElement;
      if (parent) {
        const same = Array.from(parent.children).filter((c) => c.tagName === cur.tagName && (!classes.length || classes.every((k) => c.classList.contains(k))));
        if (same.length > 1) part += ':nth-of-type(' + (Array.from(parent.children).filter((c) => c.tagName === cur.tagName).indexOf(cur) + 1) + ')';
      }
      parts.unshift(part);
      const s = parts.join(' > ');
      if (unique(s)) return s;
      if (cur === document.body) break;
      cur = cur.parentElement;
    }
    return parts.join(' > ');
  };
  const startPicker = () => {
    if (picker || !isTop) return;
    const host = document.createElement('div');
    host.style.cssText = 'all: initial; position: fixed; inset: 0; z-index: 2147483647; pointer-events: none;';
    const root = host.attachShadow({ mode: 'closed' });
    root.innerHTML = `<style>
      .box { position: fixed; border: 2px solid #0a84ff; background: rgba(10,132,255,.18); border-radius: 4px; pointer-events: none; transition: all .08s; }
      .bar { position: fixed; left: 12px; right: 12px; bottom: calc(12px + env(safe-area-inset-bottom)); background: rgba(28,28,30,.94); color: #fff; font: 13px -apple-system, system-ui; border-radius: 14px; padding: 10px; pointer-events: auto; box-shadow: 0 6px 24px rgba(0,0,0,.35); }
      .sel { font: 12px ui-monospace, Menlo, monospace; word-break: break-all; margin: 0 2px 8px; max-height: 3.6em; overflow: auto; color: #9fd0ff; }
      .row { display: flex; gap: 6px; }
      button { flex: 1; border: 0; border-radius: 9px; padding: 9px 4px; font: 600 13px -apple-system, system-ui; color: #fff; background: #3a3a3c; }
      button.primary { background: #0a84ff; } button.danger { background: #ff453a; }
      .hint { opacity: .7; margin: 0 2px 6px; }
    </style><div class="box" hidden></div><div class="bar"><div class="hint">点击网页元素以选择要隐藏的内容</div><div class="sel"></div>
    <div class="row"><button data-a="parent">扩大</button><button data-a="child">缩小</button><button data-a="cancel">取消</button><button class="primary" data-a="hide">隐藏</button></div></div>`;
    const box = root.querySelector('.box'), selText = root.querySelector('.sel');
    let current = null;
    const history = [];
    const show = (el) => {
      current = el;
      if (!el) { box.hidden = true; selText.textContent = ''; return; }
      const r = el.getBoundingClientRect();
      Object.assign(box.style, { left: r.left + 'px', top: r.top + 'px', width: r.width + 'px', height: r.height + 'px' });
      box.hidden = false;
      selText.textContent = selectorFor(el) || '';
    };
    const onClick = (e) => {
      if (e.composedPath().includes(host)) return;
      e.preventDefault(); e.stopPropagation(); e.stopImmediatePropagation();
      host.style.display = 'none';
      const el = document.elementFromPoint(e.clientX, e.clientY);
      host.style.display = '';
      history.length = 0;
      show(el);
    };
    const finish = () => {
      document.removeEventListener('click', onClick, true);
      window.removeEventListener('scroll', onScroll, true);
      host.remove();
      picker = null;
    };
    const onScroll = () => show(current);
    root.querySelector('.row').addEventListener('click', (e) => {
      const a = e.target && e.target.getAttribute && e.target.getAttribute('data-a');
      if (a === 'parent' && current && current.parentElement && current.parentElement !== document.documentElement) { history.push(current); show(current.parentElement); }
      if (a === 'child' && history.length) show(history.pop());
      if (a === 'cancel') { finish(); post('pickerDone', { cancelled: true }).catch(() => {}); }
      if (a === 'hide' && current) {
        const selector = selectorFor(current);
        hideNow(selector);
        finish();
        post('pickerDone', { selector, host: location.hostname }).catch(() => {});
      }
    });
    document.addEventListener('click', onClick, true);
    window.addEventListener('scroll', onScroll, true);
    document.documentElement.appendChild(host);
    picker = { finish };
  };

  // ---- Reader -------------------------------------------------------------------------------------
  const absolutize = (value) => { try { return new URL(value, location.href).href; } catch (_) { return value; } };
  const meta = (names) => {
    for (const n of names) {
      const el = document.querySelector(`meta[property="${n}"], meta[name="${n}"]`);
      if (el && el.content) return el.content.trim();
    }
    return '';
  };
  const unlikely = /comment|sidebar|footer|foot|nav|menu|share|social|advert|\bads?\b|promo|related|subscribe|cookie|banner|popup|modal|breadcrumb|pagination|widget|sponsor|newsletter|masthead|toolbar/i;
  const likely = /article|content|post|entry|main|body|text|story|blog|prose|rich/i;
  const extractReader = () => {
    const doc = document.cloneNode(true);
    doc.querySelectorAll('script, style, noscript, iframe, form, button, input, select, textarea, nav, footer, aside, svg, canvas, template, [hidden], [aria-hidden="true"]').forEach((n) => n.remove());
    doc.querySelectorAll('*').forEach((n) => {
      const sig = (n.className && typeof n.className === 'string' ? n.className : '') + ' ' + (n.id || '');
      if (n.tagName !== 'BODY' && n.tagName !== 'HTML' && n.tagName !== 'ARTICLE' && n.tagName !== 'MAIN' && unlikely.test(sig) && !likely.test(sig)) n.remove();
    });
    const scores = new Map();
    const addScore = (el, v) => { if (el && el.tagName) scores.set(el, (scores.get(el) || 0) + v); };
    doc.querySelectorAll('p, pre, td, blockquote, li').forEach((p) => {
      const text = p.textContent.trim();
      if (text.length < 25) return;
      const score = 1 + (text.match(/[,，、。.]/g) || []).length * 0.3 + Math.min(text.length / 100, 3);
      addScore(p.parentElement, score);
      addScore(p.parentElement && p.parentElement.parentElement, score / 2);
    });
    let best = null, bestScore = 0;
    for (const [el, s] of scores) {
      const sig = (typeof el.className === 'string' ? el.className : '') + ' ' + (el.id || '');
      const linkText = Array.from(el.querySelectorAll('a')).reduce((n, a) => n + a.textContent.length, 0);
      const density = linkText / Math.max(1, el.textContent.length);
      const adjusted = (s + (likely.test(sig) ? 5 : 0)) * (1 - density);
      if (adjusted > bestScore) { bestScore = adjusted; best = el; }
    }
    const article = doc.querySelector('article');
    if (article && article.textContent.trim().length > 500 && (!best || !article.contains(best) || article.textContent.length < best.textContent.length * 3)) {
      if (!best || article.contains(best)) best = article;
    }
    if (!best) best = doc.querySelector('main') || doc.body;
    const allowed = new Set(['P', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'IMG', 'FIGURE', 'FIGCAPTION', 'BLOCKQUOTE', 'UL', 'OL', 'LI', 'PRE', 'CODE', 'A', 'EM', 'STRONG', 'B', 'I', 'BR', 'HR', 'TABLE', 'THEAD', 'TBODY', 'TR', 'TD', 'TH', 'SUP', 'SUB', 'SPAN', 'DIV', 'SECTION', 'PICTURE', 'DL', 'DT', 'DD', 'MARK', 'S', 'U', 'SMALL', 'VIDEO', 'SOURCE']);
    const clean = (node) => {
      for (const child of Array.from(node.childNodes)) {
        if (child.nodeType === 8) { child.remove(); continue; }
        if (child.nodeType !== 1) continue;
        if (!allowed.has(child.tagName)) {
          if (child.textContent.trim().length === 0 && !child.querySelector('img')) { child.remove(); continue; }
          const span = doc.createElement('div');
          while (child.firstChild) span.appendChild(child.firstChild);
          child.replaceWith(span);
          clean(span);
          continue;
        }
        for (const attr of Array.from(child.attributes)) {
          if (!['href', 'src', 'alt', 'srcset', 'title', 'colspan', 'rowspan', 'data-src', 'data-original', 'data-lazy-src', 'poster', 'controls'].includes(attr.name)) child.removeAttribute(attr.name);
        }
        if (child.tagName === 'IMG') {
          const lazy = child.getAttribute('data-src') || child.getAttribute('data-original') || child.getAttribute('data-lazy-src');
          const src = lazy || child.getAttribute('src');
          if (!src || /^data:image\/(gif|svg)/.test(src)) { child.remove(); continue; }
          child.setAttribute('src', absolutize(src));
          child.removeAttribute('srcset');
        }
        if (child.tagName === 'A' && child.getAttribute('href')) child.setAttribute('href', absolutize(child.getAttribute('href')));
        clean(child);
      }
    };
    const content = best.cloneNode(true);
    clean(content);
    let title = meta(['og:title', 'twitter:title']) || document.title || '';
    const h1 = best.querySelector('h1') || document.querySelector('h1');
    if (h1 && h1.textContent.trim().length > 5 && title.includes(h1.textContent.trim())) title = h1.textContent.trim();
    content.querySelectorAll('h1').forEach((h) => { if (h.textContent.trim() === title) h.remove(); });
    const byline = meta(['author', 'article:author', 'byl', 'dc.creator']) ||
      ((document.querySelector('[rel="author"], .byline, .author, [itemprop="author"]') || {}).textContent || '').trim().slice(0, 120);
    const text = content.textContent.replace(/\s+/g, ' ').trim();
    return {
      title: title.trim(), byline, siteName: meta(['og:site_name', 'application-name']) || location.hostname,
      published: meta(['article:published_time', 'date', 'pubdate']), lang: document.documentElement.lang || '',
      excerpt: meta(['og:description', 'description']) || text.slice(0, 200), html: content.innerHTML, length: text.length,
      readerable: text.length > 600, url: location.href,
    };
  };

  // ---- Translation ---------------------------------------------------------------------------------
  const tr = { nodes: new Map(), seq: 0, showingOriginal: false, observer: null, active: false, pending: new Set(), timer: null };
  const skipTags = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'CODE', 'PRE', 'TEXTAREA', 'INPUT', 'SELECT', 'OPTION', 'SVG', 'MATH', 'KBD', 'SAMP', 'VAR', 'TEMPLATE', 'IFRAME', 'CANVAS']);
  const acceptNode = (node) => {
    const text = node.nodeValue;
    if (!text || !/[\p{L}]/u.test(text) || text.trim().length < 2) return false;
    for (let el = node.parentElement; el; el = el.parentElement) {
      if (skipTags.has(el.tagName)) return false;
      if (el.getAttribute('translate') === 'no' || el.classList.contains('notranslate') || el.isContentEditable) return false;
      if (el.hasAttribute('data-rikugan-tr-skip')) return false;
    }
    return true;
  };
  const collect = (root) => {
    const out = [];
    if (!root) return out;
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, { acceptNode: (n) => (acceptNode(n) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT) });
    let node;
    while ((node = walker.nextNode())) {
      if (node.__rikuganTrID) continue;
      const id = ++tr.seq;
      node.__rikuganTrID = id;
      tr.nodes.set(id, { node, original: node.nodeValue, translated: null });
      out.push({ id, text: node.nodeValue.trim() });
    }
    return out;
  };
  const translationBatches = (items) => {
    const batches = [];
    let current = [], size = 0;
    for (const item of items) {
      if (current.length && (current.length >= 50 || size + item.text.length > 4500)) { batches.push(current); current = []; size = 0; }
      current.push(item); size += item.text.length;
    }
    if (current.length) batches.push(current);
    return batches;
  };
  const startTranslation = () => {
    tr.active = true;
    tr.showingOriginal = false;
    const items = collect(document.body);
    if (!tr.observer) {
      tr.observer = new MutationObserver((mutations) => {
        if (!tr.active) return;
        for (const m of mutations) for (const n of m.addedNodes) { if (n.nodeType === 1 || n.nodeType === 3) tr.pending.add(n.nodeType === 3 ? n.parentElement : n); }
        clearTimeout(tr.timer);
        tr.timer = setTimeout(() => {
          const more = [];
          for (const el of tr.pending) if (el && el.isConnected) more.push(...collect(el));
          tr.pending.clear();
          if (more.length) post('translateMore', { batches: translationBatches(more) }).catch(() => {});
        }, 800);
      });
      tr.observer.observe(document.body, { childList: true, subtree: true });
    }
    return translationBatches(items);
  };
  const applyTranslations = (list) => {
    for (const item of list || []) {
      const entry = tr.nodes.get(item.id);
      if (!entry || typeof item.text !== 'string') continue;
      const lead = /^\s*/.exec(entry.original)[0], trail = /\s*$/.exec(entry.original)[0];
      entry.translated = lead + item.text + trail;
      if (!tr.showingOriginal && entry.node.isConnected) entry.node.nodeValue = entry.translated;
    }
    return true;
  };
  const showOriginal = (flag) => {
    tr.showingOriginal = !!flag;
    for (const entry of tr.nodes.values()) {
      if (!entry.node.isConnected) continue;
      entry.node.nodeValue = flag || !entry.translated ? entry.original : entry.translated;
    }
    return true;
  };
  const stopTranslation = () => {
    showOriginal(true);
    tr.active = false;
    if (tr.observer) { tr.observer.disconnect(); tr.observer = null; }
    for (const entry of tr.nodes.values()) delete entry.node.__rikuganTrID;
    tr.nodes.clear();
    return true;
  };
  const languageSample = () => ({
    lang: document.documentElement.lang || (document.querySelector('meta[http-equiv="content-language"]') || {}).content || '',
    sample: (document.body ? document.body.innerText : '').replace(/\s+/g, ' ').slice(0, 1500),
  });

  // ---- Images & media --------------------------------------------------------------------------------
  const pickSrcset = (srcset) => {
    let best = null, bestW = 0;
    for (const part of String(srcset || '').split(',')) {
      const [u, d] = part.trim().split(/\s+/);
      if (!u) continue;
      const w = d ? parseFloat(d) * (d.endsWith('x') ? 1000 : 1) : 1;
      if (w >= bestW) { bestW = w; best = u; }
    }
    return best;
  };
  const scanImages = () => {
    const out = new Map();
    const add = (src, w, h, alt) => {
      if (!src || src.startsWith('data:image/svg') || src.length > 200000) return;
      const url = absolutize(src);
      if (!/^(https?:|data:image|blob:)/.test(url)) return;
      const prev = out.get(url);
      if (!prev || (w * h > prev.width * prev.height)) out.set(url, { url, width: w || 0, height: h || 0, alt: alt || '' });
    };
    document.querySelectorAll('img').forEach((img) => {
      const large = pickSrcset(img.getAttribute('srcset')) || img.getAttribute('data-src') || img.getAttribute('data-original');
      add(img.currentSrc || img.src, img.naturalWidth, img.naturalHeight, img.alt);
      if (large) add(large, img.naturalWidth, img.naturalHeight, img.alt);
    });
    document.querySelectorAll('picture source[srcset]').forEach((s) => add(pickSrcset(s.getAttribute('srcset')), 0, 0, ''));
    document.querySelectorAll('video[poster]').forEach((v) => add(v.poster, v.videoWidth, v.videoHeight, 'poster'));
    const og = meta(['og:image', 'twitter:image']);
    if (og) add(og, 0, 0, 'og:image');
    let checked = 0;
    for (const el of document.querySelectorAll('div, section, a, span, figure, header, li')) {
      if (checked++ > 1500) break;
      const bg = el.style && el.style.backgroundImage || '';
      const m = /url\(["']?([^"')]+)["']?\)/.exec(bg || (el.clientWidth > 120 ? getComputedStyle(el).backgroundImage : ''));
      if (m) add(m[1], el.clientWidth, el.clientHeight, 'background');
    }
    return Array.from(out.values()).filter((i) => !(i.width && i.width < 24 && i.height && i.height < 24));
  };
  const mediaRegex = /\.(m3u8|mp4|m4v|webm|mov|mkv|mp3|m4a|aac|ogg|oga|opus|flac|wav|mpd|flv)(\?|#|$)/i;
  const kindOf = (url, fallback) => {
    if (/\.(mp3|m4a|aac|ogg|oga|opus|flac|wav)(\?|#|$)/i.test(url)) return 'audio';
    if (/\.(m3u8)(\?|#|$)/i.test(url)) return 'hls';
    if (/\.(mpd)(\?|#|$)/i.test(url)) return 'dash';
    return fallback || 'video';
  };
  const scanMedia = () => {
    const out = new Map();
    const add = (src, kind, extra) => {
      if (!src) return;
      const url = absolutize(src);
      if (!out.has(url)) out.set(url, Object.assign({ url, kind: kindOf(url, kind), source: 'dom' }, extra || {}));
    };
    document.querySelectorAll('video, audio').forEach((m) => {
      const extra = { width: m.videoWidth || 0, height: m.videoHeight || 0, duration: isFinite(m.duration) ? m.duration : 0, playing: !m.paused };
      const kind = m.tagName === 'AUDIO' ? 'audio' : 'video';
      if (m.currentSrc) add(m.currentSrc, kind, extra);
      else if (m.src) add(m.src, kind, extra);
      m.querySelectorAll('source').forEach((s) => add(s.src, kind, extra));
    });
    try {
      for (const e of performance.getEntriesByType('resource')) {
        if (mediaRegex.test(e.name) || e.initiatorType === 'video' || e.initiatorType === 'audio') add(e.name, undefined, { source: 'network', size: e.transferSize || e.encodedBodySize || 0 });
      }
    } catch (_) {}
    return Array.from(out.values());
  };
  const largestVideo = () => {
    let best = null, area = 0;
    document.querySelectorAll('video').forEach((v) => {
      const r = v.getBoundingClientRect();
      const a = r.width * r.height + (v.paused ? 0 : 1e7);
      if (a > area) { area = a; best = v; }
    });
    return best;
  };
  const videoAction = (action) => {
    const v = largestVideo();
    if (!v) return 'no-video';
    try {
      if (action === 'pip') {
        if (v.webkitSupportsPresentationMode && v.webkitSupportsPresentationMode('picture-in-picture')) {
          v.webkitSetPresentationMode(v.webkitPresentationMode === 'picture-in-picture' ? 'inline' : 'picture-in-picture');
        } else if (v.requestPictureInPicture) v.requestPictureInPicture();
        else return 'unsupported';
      } else if (action === 'fullscreen') {
        if (v.webkitEnterFullscreen) v.webkitEnterFullscreen(); else if (v.requestFullscreen) v.requestFullscreen();
      } else if (action === 'play') { v.paused ? v.play() : v.pause(); }
      return 'ok';
    } catch (e) { return String(e && e.message || e); }
  };

  // ---- Autofill ----------------------------------------------------------------------------------------
  const visible = (el) => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0 && getComputedStyle(el).visibility !== 'hidden'; };
  const setValue = (el, value) => {
    if (value === undefined || value === null) return;
    const proto = el.tagName === 'SELECT' ? HTMLSelectElement.prototype : el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
    el.focus();
    setter.call(el, String(value));
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    el.blur();
  };
  const loginFields = () => {
    const pw = Array.from(document.querySelectorAll('input[type="password"]')).find(visible);
    if (!pw) return null;
    const scope = pw.form || document;
    const candidates = Array.from(scope.querySelectorAll('input:not([type="password"]):not([type="hidden"]):not([type="checkbox"]):not([type="radio"]):not([type="submit"]):not([type="button"])')).filter(visible);
    const before = candidates.filter((c) => c.compareDocumentPosition(pw) & Node.DOCUMENT_POSITION_FOLLOWING);
    const user = before.reverse().find((c) => /email|user|login|account|name|phone|mail/i.test((c.name || '') + (c.id || '') + (c.autocomplete || '') + (c.type || ''))) || before[0] || null;
    return { user, pw };
  };
  const autofillInfo = () => {
    const f = loginFields();
    return { hasLogin: !!f, hasCard: !!document.querySelector('input[autocomplete^="cc-"], input[name*="card" i]'), hasAddress: !!document.querySelector('input[autocomplete*="address"], input[autocomplete="email"], input[autocomplete="tel"]') };
  };
  const fillLogin = (cred) => {
    const f = loginFields();
    if (!f) return false;
    if (f.user && cred.username) setValue(f.user, cred.username);
    setValue(f.pw, cred.password);
    return true;
  };
  const fieldMap = [
    ['name', /(^|\b)(full.?name|your.?name|^name$)/i, 'name'], ['given-name', /first.?name|given/i, 'givenName'], ['family-name', /last.?name|surname|family/i, 'familyName'],
    ['email', /e.?mail/i, 'email'], ['tel', /phone|mobile|tel/i, 'phone'], ['organization', /company|organi[sz]ation/i, 'organization'],
    ['street-address', /address|street/i, 'street'], ['address-line1', /address.?1|street/i, 'street'], ['address-level2', /city|town/i, 'city'],
    ['address-level1', /state|province|region/i, 'region'], ['postal-code', /zip|postal|postcode/i, 'postalCode'], ['country', /country/i, 'country'],
    ['cc-name', /card.?holder|name.?on.?card/i, 'cardName'], ['cc-number', /card.?number|cc.?num/i, 'cardNumber'],
    ['cc-exp-month', /exp.*month|cc.?month/i, 'expMonth'], ['cc-exp-year', /exp.*year|cc.?year/i, 'expYear'], ['cc-exp', /expir|exp.?date/i, 'exp'],
    ['cc-csc', /cvc|cvv|security.?code/i, 'cvc'],
  ];
  const fillForm = (data) => {
    let filled = 0;
    for (const input of document.querySelectorAll('input, select, textarea')) {
      if (!visible(input) || input.type === 'password' || input.type === 'hidden') continue;
      const ac = (input.getAttribute('autocomplete') || '').toLowerCase();
      const sig = (input.name || '') + ' ' + (input.id || '') + ' ' + (input.placeholder || '') + ' ' + (input.getAttribute('aria-label') || '');
      for (const [token, re, key] of fieldMap) {
        if (data[key] === undefined || data[key] === '') continue;
        if (ac.split(/\s+/).includes(token) || (!ac && re.test(sig))) { setValue(input, key === 'exp' ? data.expMonth + '/' + String(data.expYear).slice(-2) : data[key]); filled++; break; }
      }
    }
    return filled;
  };
  document.addEventListener('submit', (e) => {
    const form = e.target;
    const pw = form && form.querySelector && form.querySelector('input[type="password"]');
    if (!pw || !pw.value) return;
    const f = loginFields();
    post('credentialCaptured', { username: f && f.user ? f.user.value : '', password: pw.value, host: location.hostname }).catch(() => {});
  }, true);

  // ---- Find in page ----------------------------------------------------------------------------------
  // Case-insensitive text search over visible text. Matches are painted with the CSS Custom
  // Highlight API (no DOM changes, so page scripts and layout are untouched); without it the
  // current match is shown as the selection.
  let found = { ranges: [], index: -1 };
  const hasHighlights = () => !!(window.CSS && CSS.highlights && window.Highlight);
  const findPaint = () => {
    const current = found.ranges[found.index];
    if (hasHighlights()) {
      CSS.highlights.set('rikugan-find', new Highlight(...found.ranges));
      if (current) CSS.highlights.set('rikugan-find-current', new Highlight(current)); else CSS.highlights.delete('rikugan-find-current');
    } else if (current) {
      const sel = window.getSelection(); sel.removeAllRanges(); sel.addRange(current);
    }
    if (current) {
      const rect = current.getBoundingClientRect();
      if (rect.top < 80 || rect.bottom > innerHeight - 80) window.scrollBy({ top: rect.top - innerHeight / 3, behavior: 'smooth' });
    }
    return { count: found.ranges.length, index: found.index };
  };
  const findClear = () => {
    if (hasHighlights()) { CSS.highlights.delete('rikugan-find'); CSS.highlights.delete('rikugan-find-current'); }
    found = { ranges: [], index: -1 };
    return { count: 0, index: -1 };
  };
  const findStart = (query) => {
    findClear();
    const q = String(query || '').toLocaleLowerCase();
    if (!q || !document.body) return { count: 0, index: -1 };
    setSheet('find', '::highlight(rikugan-find){background-color:rgba(255,214,10,.55);color:inherit}' +
      '::highlight(rikugan-find-current){background-color:rgba(255,149,0,.95);color:#000}');
    const skip = /^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE|TEXTAREA|SELECT|OPTION)$/;
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
      acceptNode: (node) => {
        const parent = node.parentElement;
        if (!parent || skip.test(parent.tagName) || !node.nodeValue.trim()) return NodeFilter.FILTER_REJECT;
        return parent.getClientRects().length ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
      },
    });
    for (let node = walker.nextNode(); node && found.ranges.length < 2000; node = walker.nextNode()) {
      const text = node.nodeValue.toLocaleLowerCase();
      for (let at = text.indexOf(q); at !== -1 && found.ranges.length < 2000; at = text.indexOf(q, at + q.length)) {
        const range = document.createRange();
        range.setStart(node, at); range.setEnd(node, at + q.length);
        found.ranges.push(range);
      }
    }
    // Start at the first match below the current scroll position, like Safari.
    found.index = found.ranges.length ? Math.max(0, found.ranges.findIndex((r) => r.getBoundingClientRect().top >= 0)) : -1;
    return findPaint();
  };
  const findStep = (forward) => {
    if (!found.ranges.length) return { count: 0, index: -1 };
    found.index = (found.index + (forward ? 1 : -1) + found.ranges.length) % found.ranges.length;
    return findPaint();
  };

  // ---- Tab mute (GM_audio) ----------------------------------------------------------------------------
  // Media elements of this document stay muted while the tab is muted, including ones that start
  // playing later; elements muted by us are restored on unmute.
  let tabMuted = false;
  const mutedByUs = new WeakSet();
  const isMedia = (el) => el && (el.tagName === 'VIDEO' || el.tagName === 'AUDIO');
  const muteElement = (el) => { if (tabMuted && !el.muted) { mutedByUs.add(el); el.muted = true; } };
  const setMuted = (value) => {
    tabMuted = !!value;
    document.querySelectorAll('video, audio').forEach((el) => {
      if (tabMuted) muteElement(el);
      else if (mutedByUs.has(el)) { mutedByUs.delete(el); el.muted = false; }
    });
    return tabMuted;
  };
  for (const type of ['play', 'playing', 'volumechange', 'loadedmetadata']) {
    document.addEventListener(type, (e) => { if (tabMuted && isMedia(e.target)) muteElement(e.target); }, true);
  }
  const audible = () => Array.from(document.querySelectorAll('video, audio')).some((m) => !m.paused && !m.ended && !m.muted && m.volume > 0);

  // ---- Public API (called from Swift through evaluateJavaScript in this world) ------------------------
  window.__rikuganTools = {
    applyDarkMode, applyFont, fontStatus, applyCosmetic, hideNow, startPicker, stopPicker: () => picker && picker.finish(), selectorFor,
    extractReader, startTranslation, applyTranslations, showOriginal, stopTranslation, languageSample,
    scanImages, scanMedia, videoAction, autofillInfo, fillLogin, fillForm,
    selection: () => String(window.getSelection ? window.getSelection() : ''),
    findStart, findStep, findClear, setMuted, audible,
  };
  if (cfg.muted) setMuted(true);

  applyDarkMode(cfg.dark);
  if (cfg.font) applyFont(cfg.font);
  if (cfg.cosmetic && (cfg.cosmetic.selectors.length || cfg.cosmetic.css.length)) applyCosmetic(cfg.cosmetic.selectors, cfg.cosmetic.css);
  post('frame', { url: location.href, top: isTop }).catch(() => {});
  if (isTop) {
    const signal = (type) => post('lifecycle', { type, url: location.href }).catch(() => {});
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => signal('DOMContentLoaded'), { once: true });
    else signal('DOMContentLoaded');
  }
})(/*__RK_TOOLS_CONFIG__*/null);
