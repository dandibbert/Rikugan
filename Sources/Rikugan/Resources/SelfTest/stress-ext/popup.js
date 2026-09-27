// Sends immediately on load, i.e. possibly while the background is still starting.
chrome.runtime.sendMessage({ type: 'ping', n: 'popup' }).then(
  (r) => chrome.storage.local.set({ popupPong: r && r.pong === 'popup' ? 'ok' : 'bad' }),
  (e) => chrome.storage.local.set({ popupPong: 'error:' + e.message }));
