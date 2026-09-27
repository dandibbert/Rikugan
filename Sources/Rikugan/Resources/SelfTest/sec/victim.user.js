// ==UserScript==
// @name         SEC victim (isolated)
// @namespace    https://rikugan.local/sec
// @version      1.0
// @match        http://127.0.0.1:*/sec/*
// @grant        GM_getValue
// @grant        GM_setValue
// @grant        GM_xmlhttpRequest
// @grant        GM_openInTab
// @grant        GM_registerMenuCommand
// @run-at       document-end
// ==/UserScript==
(function () {
  GM_setValue('secret', 'victim-secret');
  GM_registerMenuCommand('Victim command', () => document.documentElement.setAttribute('data-victim-menu', 'ran'));
  document.documentElement.setAttribute('data-victim-ready', GM_getValue('secret') === 'victim-secret' ? 'ok' : 'fail');
})();
