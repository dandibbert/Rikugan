(() => {
  const port = chrome.runtime.connect({ name: 'a-port' });
  // Deliberate leak for the test: the attacker gets A's port id.
  document.documentElement.setAttribute('data-a-port', port._id || '');
  globalThis.__aEcho = (say) => new Promise((resolve, reject) => {
    const onMessage = (m) => { if (m && m.echo === say) { port.onMessage.removeListener(onMessage); resolve(m.echo); } };
    port.onMessage.addListener(onMessage);
    port.postMessage({ say });
    setTimeout(() => reject(new Error('timeout')), 10000);
  });
  document.documentElement.setAttribute('data-a-ready', '1');
})();
