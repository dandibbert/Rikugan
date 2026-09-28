// ==UserScript==
// @name         Rikugan Self-Test Userscript
// @namespace    https://rikugan.local/selftest
// @version      1.0
// @description  Exercises GM storage, XHR, style and menu commands.
// @match        http://127.0.0.1:*/index.html*
// @exclude      http://127.0.0.1:*/index.html?skip*
// @grant        GM_setValue
// @grant        GM_getValue
// @grant        GM_listValues
// @grant        GM_deleteValue
// @grant        GM_addStyle
// @grant        GM_xmlhttpRequest
// @grant        GM_registerMenuCommand
// @grant        GM_info
// @grant        GM_cookie
// @grant        GM_saveTab
// @grant        GM_getTab
// @grant        GM_audio
// @run-at       document-end
// ==/UserScript==

(function () {
  'use strict';
  const root = document.documentElement;
  root.setAttribute('data-us', 'ran');
  root.setAttribute('data-us-handler', GM_info.scriptHandler);
  const count = GM_getValue('runs', 0) + 1;
  GM_setValue('runs', count);
  GM_setValue('obj', { a: [1, 2, 3] });
  root.setAttribute('data-gm-storage', GM_getValue('obj').a[2] === 3 && GM_listValues().includes('runs') ? 'ok' : 'fail');
  root.setAttribute('data-gm-runs', String(count));
  GM_addStyle('#gm-style { color: rgb(4, 5, 6) !important; }');
  GM_xmlhttpRequest({
    method: 'GET',
    url: '/data.json',
    responseType: 'json',
    onload: (r) => root.setAttribute('data-gmxhr', r.status === 200 && r.response && r.response.value === 42 ? 'ok' : 'fail:' + r.status),
    onerror: (e) => root.setAttribute('data-gmxhr', 'error:' + (e && e.error)),
  });
  GM_registerMenuCommand('Self-test command', () => root.setAttribute('data-menu', 'ok'));
  root.setAttribute('data-unsafe-window', typeof unsafeWindow === 'object' ? 'ok' : 'fail');
  // GM_cookie (incl. HttpOnly), per-tab values and tab mute round trips.
  (async () => {
    const out = [];
    const name = 'rk_selftest_' + count;
    await GM_cookie.set({ name, value: 'v1', path: '/', httpOnly: true });
    const listed = await GM_cookie.list({ name });
    out.push(listed.length === 1 && listed[0].value === 'v1' && listed[0].httpOnly === true ? 'cookie' : 'cookie-bad:' + JSON.stringify(listed));
    await GM_cookie.delete({ name });
    const gone = await GM_cookie.list({ name });
    if (gone.length) out.push('cookie-delete-bad');
    await GM_saveTab({ marker: count });
    const tab = await GM_getTab();
    out.push(tab && tab.marker === count ? 'tab' : 'tab-bad:' + JSON.stringify(tab));
    await GM_audio.setMute({ isMuted: true });
    const muted = await GM_audio.getState();
    await GM_audio.setMute({ isMuted: false });
    const unmuted = await GM_audio.getState();
    out.push(muted.isMuted === true && unmuted.isMuted === false ? 'audio' : 'audio-bad');
    root.setAttribute('data-gm-extras', out.join(','));
  })().catch((e) => root.setAttribute('data-gm-extras', 'error:' + (e && e.message || e)));
})();
