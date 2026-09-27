// ==UserScript==
// @name         PW isolated (granted)
// @namespace    https://rikugan.local/pageworld
// @version      1.0
// @match        http://127.0.0.1:*/pageworld/*
// @grant        GM_getValue
// @grant        GM_setValue
// @run-at       document-end
// ==/UserScript==
(function () {
  const r = document.documentElement;
  // Isolation: the page's globals are not visible and ours do not leak to the page.
  r.setAttribute('data-iso-value', typeof window.pageValue);
  window.isolatedLeak = 'leak';
  GM_setValue('iso', 1);
  r.setAttribute('data-iso-gm', GM_getValue('iso') === 1 ? 'ok' : 'fail');
  // The DOM is shared, so DOM events still cross worlds.
  document.addEventListener('rk-page-event', function (e) { r.setAttribute('data-iso-event', String(e.detail)); });
})();
