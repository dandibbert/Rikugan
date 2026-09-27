// ==UserScript==
// @name         PW unsafeWindow
// @namespace    https://rikugan.local/pageworld
// @version      1.0
// @match        http://127.0.0.1:*/pageworld/*
// @grant        GM_getValue
// @grant        GM_setValue
// @grant        unsafeWindow
// @run-at       document-end
// ==/UserScript==
(function () {
  const r = document.documentElement;
  r.setAttribute('data-unsafe-value', String(unsafeWindow.pageValue));
  r.setAttribute('data-unsafe-fn', String(unsafeWindow.pageFunction('b')));
  unsafeWindow.pageObject.nested.n = 2;
  unsafeWindow.fromUnsafe = 'unsafe';
  if (window.top === window) {
    const runs = GM_getValue('runs', 0) + 1;
    GM_setValue('runs', runs);
    r.setAttribute('data-unsafe-runs', String(runs));
  }
  r.setAttribute('data-unsafe-gm', GM_getValue('runs', 0) >= 1 || window.top !== window ? 'ok' : 'fail');
  unsafeWindow.document.addEventListener('rk-page-event', function (e) { r.setAttribute('data-unsafe-event', String(e.detail)); });
})();
