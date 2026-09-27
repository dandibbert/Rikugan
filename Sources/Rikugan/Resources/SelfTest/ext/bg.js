// Test 7: background service worker – event wake-up + message handling.
chrome.runtime.onInstalled.addListener(() => { chrome.storage.local.set({ installedAt: Date.now() }); });

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message) return false;
  if (message.type === 'ping') {
    (async () => {
      const hasHost = await chrome.permissions.contains({ origins: ['http://127.0.0.1/*'] });
      await chrome.storage.local.set({ bgSeen: sender.tab ? sender.tab.id : -1 });
      const got = await chrome.storage.local.get('bgSeen');
      sendResponse({ pong: true, hasHost, bgStorage: got.bgSeen === (sender.tab ? sender.tab.id : -1) });
      // tabs.sendMessage back to the content script.
      if (sender.tab) {
        try {
          const r = await chrome.tabs.sendMessage(sender.tab.id, { type: 'toContent' });
          await chrome.storage.local.set({ contentReplied: !!(r && r.fromContent) });
        } catch (e) { await chrome.storage.local.set({ contentReplied: 'error:' + e.message }); }
      }
    })();
    return true;
  }
  if (message.type === 'runScripting' && sender.tab) {
    chrome.scripting.executeScript({
      target: { tabId: sender.tab.id },
      func: (tag) => { document.documentElement.setAttribute('data-scripting', tag); return 40 + 2; },
      args: ['ok'],
    }).then((results) => sendResponse({ result: results[0].result }), (e) => sendResponse({ error: e.message }));
    return true;
  }
  if (message.type === 'unsupported') {
    // Unsupported APIs must reject with an explicit error, never be undefined.
    Promise.resolve().then(() => chrome.debugger.attach({ tabId: 1 }, '1.3'))
      .then(() => sendResponse({ ok: false }), (e) => sendResponse({ ok: /Unsupported API/.test(e.message) }));
    return true;
  }
  return false;
});

chrome.runtime.onConnect.addListener((port) => {
  port.onMessage.addListener((m) => { if (m && m.say) port.postMessage({ echo: m.say }); });
});
