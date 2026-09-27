// A fresh id per background context: lets the runner prove a wake really created a new runtime.
const wakeId = Math.random().toString(36).slice(2);
let disconnectChain = Promise.resolve();

chrome.runtime.onMessage.addListener((m, sender, send) => {
  if (!m) return false;
  if (m.type === 'ping') { send({ pong: m.n, wake: wakeId, fromTab: sender.tab ? sender.tab.id : null }); return false; }
  if (m.type === 'storage') {
    const key = 'k' + m.n;
    chrome.storage.local.set({ [key]: m.n })
      .then(() => chrome.storage.local.get(key))
      .then((got) => send({ value: got[key], wake: wakeId }), (e) => send({ error: String(e && e.message) }));
    return true;
  }
  return false;
});

chrome.runtime.onConnect.addListener((port) => {
  port.onMessage.addListener((m) => port.postMessage({ echo: m && m.say, name: port.name, wake: wakeId }));
  port.onDisconnect.addListener(() => {
    // Serialised so concurrent disconnects never lose an update.
    disconnectChain = disconnectChain.then(async () => {
      const got = await chrome.storage.local.get('disconnects');
      await chrome.storage.local.set({ disconnects: (got.disconnects || 0) + 1 });
    });
  });
});
