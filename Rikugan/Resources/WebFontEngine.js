(() => {
  'use strict';
  if (globalThis.RikuganWebFonts) return;
  const excluded = 'script,style,noscript,svg,canvas,math,pre,code,kbd,samp,i,[class*="icon" i],[class*="glyph" i],[class*="material-symbol" i],[class*="material-icon" i],[data-icon],[aria-hidden="true"]';
  const symbolFamily = /icon|awesome|material|glyph|wingdings|webdings|symbol|phosphor|remix|mdl2/i;
  const originals = new Map();
  let observer = null, family = '', scheduled = false;
  const pending = new Set();
  const hasText = element => ['INPUT', 'TEXTAREA', 'SELECT'].includes(element.tagName)
    || Array.from(element.childNodes || []).some(node => node.nodeType === 3 && String(node.nodeValue || '').trim());
  function candidates(node) {
    if (!node || node.nodeType !== 1) return [];
    return [node, ...Array.from(node.querySelectorAll('*'))].filter(element => {
      if (originals.has(element) || !hasText(element)) return false;
      if (element.closest(excluded) || element.querySelector(excluded)) return false;
      if (symbolFamily.test(getComputedStyle(element).fontFamily)) return false;
      const text = String(element.textContent || '').trim();
      if (text && /^[\s\uE000-\uF8FF\u{F0000}-\u{FFFFD}\u{100000}-\u{10FFFD}]+$/u.test(text)) return false;
      return true;
    });
  }
  function scan(node) {
    if (!family) return;
    const elements = candidates(node);
    for (const element of elements) {
      originals.set(element, [element.style.getPropertyValue('font-family'), element.style.getPropertyPriority('font-family')]);
      element.style.setProperty('font-family', JSON.stringify(family) + ', sans-serif', 'important');
    }
    for (const element of originals.keys()) if (!element.isConnected) originals.delete(element);
  }
  function reset() {
    if (observer) observer.disconnect();
    observer = null; pending.clear();
    for (const [element, [value, priority]] of originals) {
      if (value) element.style.setProperty('font-family', value, priority);
      else element.style.removeProperty('font-family');
    }
    originals.clear();
  }
  function apply(nextFamily, faceCSS = '') {
    reset(); family = String(nextFamily || '');
    const doc = globalThis.document;
    if (!doc) return;
    let style = doc.getElementById('rikugan-font-face');
    if (!family || !faceCSS) { if (style) style.remove(); }
    else {
      if (!style) { style = doc.createElement('style'); style.id = 'rikugan-font-face'; doc.documentElement.appendChild(style); }
      style.textContent = faceCSS;
    }
    if (!family || !doc.documentElement) return;
    scan(doc.body || doc.documentElement);
    observer = new MutationObserver(records => {
      for (const record of records) for (const node of record.addedNodes) if (node.nodeType === 1) pending.add(node);
      if (scheduled || !pending.size) return;
      scheduled = true;
      setTimeout(() => { scheduled = false; for (const node of pending) scan(node); pending.clear(); }, 60);
    });
    observer.observe(doc.documentElement, {subtree: true, childList: true});
  }
  globalThis.RikuganWebFonts = Object.freeze({apply});
})();
