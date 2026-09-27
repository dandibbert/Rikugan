// ==UserScript==
// @name         PW privileged unsafeWindow
// @namespace    https://rikugan.local/pageworld
// @version      1.0
// @match        http://127.0.0.1:*/pageworld/*
// @grant        GM_getValue
// @grant        GM_setValue
// @grant        unsafeWindow
// @run-at       document-end
// ==/UserScript==
// Privileged grants → isolated world for security; unsafeWindow is the isolated window
// (shared DOM, page JS globals not visible). Documented Partial.
(function () {
  const r = document.documentElement;
  r.setAttribute('data-pu-value', typeof unsafeWindow.pageValue);
  r.setAttribute('data-pu-same', String(unsafeWindow === window));
  unsafeWindow.fromPrivileged = 'leaked';
  GM_setValue('pu', 7);
  r.setAttribute('data-pu-gm', GM_getValue('pu') === 7 ? 'ok' : 'fail');
})();
