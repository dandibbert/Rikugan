// ==UserScript==
// @name         PW inject-into page
// @namespace    https://rikugan.local/pageworld
// @version      2.0
// @match        http://127.0.0.1:*/pageworld/*
// @inject-into  page
// @grant        GM_info
// @grant        GM_setValue
// @run-at       document-end
// ==/UserScript==
// Forced into the page world: GM_info works, privileged GM_setValue must be refused explicitly.
(function () {
  const r = document.documentElement;
  r.setAttribute('data-inject-value', String(window.pageValue));
  r.setAttribute('data-inject-info', typeof GM_info === 'object' && GM_info.script.name === 'PW inject-into page' ? 'ok' : 'missing');
  try { GM_setValue('x', 1); r.setAttribute('data-inject-gm', 'allowed'); }
  catch (e) { r.setAttribute('data-inject-gm', /page-world/.test(e.message) ? 'denied' : 'other:' + e.message); }
  window.fromInjectPage = 'inject';
})();
