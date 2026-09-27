let chain = Promise.resolve();
chrome.runtime.onInstalled.addListener(() => { chrome.storage.local.set({ aSecret: 'a-secret' }); });
chrome.runtime.onConnect.addListener((port) => {
  port.onMessage.addListener((m) => {
    const said = String(m && m.say !== undefined ? m.say : JSON.stringify(m));
    chain = chain.then(async () => {
      const got = await chrome.storage.local.get('portLog');
      const log = got.portLog || [];
      log.push(said);
      await chrome.storage.local.set({ portLog: log });
    });
    port.postMessage({ echo: m && m.say });
  });
});
chrome.runtime.onMessage.addListener((m, sender, send) => {
  if (m && m.type === 'evil') { chrome.storage.local.set({ evilMessage: true }); }
  return false;
});
