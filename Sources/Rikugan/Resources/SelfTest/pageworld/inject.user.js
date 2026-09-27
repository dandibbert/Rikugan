// ==UserScript==
// @name         PW inject-into page
// @namespace    https://rikugan.local/pageworld
// @version      1.0
// @match        http://127.0.0.1:*/pageworld/*
// @inject-into  page
// @grant        GM_info
// @run-at       document-end
// ==/UserScript==
(function () {
  const r = document.documentElement;
  r.setAttribute('data-inject-value', String(window.pageValue));
  r.setAttribute('data-inject-info', typeof GM_info === 'object' && GM_info.script.name === 'PW inject-into page' ? 'ok' : 'missing');
  window.fromInjectPage = 'inject';
})();
