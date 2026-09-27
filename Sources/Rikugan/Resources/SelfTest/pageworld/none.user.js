// ==UserScript==
// @name         PW grant none
// @namespace    https://rikugan.local/pageworld
// @version      1.0
// @match        http://127.0.0.1:*/pageworld/*
// @grant        none
// @run-at       document-end
// ==/UserScript==
(function () {
  const r = document.documentElement;
  r.setAttribute('data-none-value', String(window.pageValue));
  r.setAttribute('data-none-fn', String(window.pageFunction('a')));
  r.setAttribute('data-none-obj', String(window.pageObject.list.length));
  window.fromGrantNone = 'none';
  document.addEventListener('rk-page-event', function (e) { r.setAttribute('data-none-event', String(e.detail)); });
  document.dispatchEvent(new CustomEvent('rk-from-script', { detail: 'none' }));
  r.setAttribute('data-none-runs', String((Number(r.getAttribute('data-none-runs')) || 0) + 1));
})();
