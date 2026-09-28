// Tests 1-3 + 5 + 7 from the content-script side.
(async function () {
  const root = document.documentElement;
  const set = (k, v) => root.setAttribute('data-' + k, v);
  set('cs-end', document.body ? 'ok' : 'fail');
  // Test 3: storage.
  try {
    await chrome.storage.local.set({ selftest: { n: 7, s: 'x' } });
    const got = await chrome.storage.local.get('selftest');
    set('storage', got.selftest && got.selftest.n === 7 ? 'ok' : 'fail');
  } catch (e) { set('storage', 'error:' + e.message); }
  // tabs.sendMessage target.
  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    if (message && message.type === 'toContent') { set('to-content', 'ok'); sendResponse({ fromContent: true }); }
  });
  // Test 2 + 7: runtime messaging wakes the background worker.
  try {
    const reply = await chrome.runtime.sendMessage({ type: 'ping' });
    set('messaging', reply && reply.pong ? 'ok' : 'fail');
    set('permissions', reply && reply.hasHost ? 'ok' : 'fail');
    set('bg-storage', reply && reply.bgStorage ? 'ok' : 'fail');
  } catch (e) { set('messaging', 'error:' + e.message); }
  // Port messaging.
  try {
    const port = chrome.runtime.connect({ name: 'selftest' });
    port.onMessage.addListener((m) => { if (m && m.echo === 'hello') set('port', 'ok'); });
    port.postMessage({ say: 'hello' });
  } catch (e) { set('port', 'error:' + e.message); }
  // Test 5: ask the background to run chrome.scripting.executeScript on this tab.
  try {
    const r = await chrome.runtime.sendMessage({ type: 'runScripting' });
    set('scripting-result', r && r.result === 42 ? 'ok' : 'fail:' + JSON.stringify(r));
  } catch (e) { set('scripting-result', 'error:' + e.message); }
  set('extras', await chrome.runtime.sendMessage({ type: 'extras' }).then((r) => r && r.result, (e) => 'error:' + e.message));
  set('unsupported', await chrome.runtime.sendMessage({ type: 'unsupported' }).then((r) => r && r.ok ? 'ok' : 'fail', (e) => 'error:' + e.message));
})();
