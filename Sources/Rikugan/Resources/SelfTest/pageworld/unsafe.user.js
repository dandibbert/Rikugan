// ==UserScript==
// @name         PW unsafeWindow
// @namespace    https://rikugan.local/pageworld
// @version      2.0
// @match        http://127.0.0.1:*/pageworld/*
// @grant        unsafeWindow
// @grant        GM_addStyle
// @run-at       document-end
// ==/UserScript==
// Only non-privileged grants → runs as page JS with the real page window.
(function () {
  const r = document.documentElement;
  r.setAttribute('data-unsafe-value', String(unsafeWindow.pageValue));
  r.setAttribute('data-unsafe-fn', String(unsafeWindow.pageFunction('b')));
  unsafeWindow.pageObject.nested.n = 2;
  unsafeWindow.fromUnsafe = 'unsafe';
  r.setAttribute('data-unsafe-gm', GM_addStyle('.rk-unsafe-marker{}') ? 'ok' : 'fail');
  unsafeWindow.document.addEventListener('rk-page-event', function (e) { r.setAttribute('data-unsafe-event', String(e.detail)); });
})();
