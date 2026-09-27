// ==UserScript==
// @name         SEC victim (page world)
// @namespace    https://rikugan.local/sec
// @version      1.0
// @match        http://127.0.0.1:*/sec/*
// @inject-into  page
// @grant        GM_setValue
// @run-at       document-end
// ==/UserScript==
(function () {
  try { GM_setValue('k', 'v'); document.documentElement.setAttribute('data-victim-page', 'allowed'); }
  catch (e) { document.documentElement.setAttribute('data-victim-page', /page-world/.test(e.message) ? 'denied' : 'other'); }
})();
