// Runner-facing helpers in the extension's content world. Every call has its own deadline and
// rejects on timeout — nothing retries.
(() => {
  const ports = {};
  const deadline = (p, ms, what) => Promise.race([p, new Promise((_, reject) => setTimeout(() => reject(new Error('timeout: ' + what)), ms))]);
  const open = (name) => { ports[name] = chrome.runtime.connect({ name }); return true; };
  const echo = (name, say, ms) => {
    const port = ports[name];
    if (!port) return Promise.reject(new Error('no port ' + name));
    return deadline(new Promise((resolve) => {
      const onMessage = (m) => { if (m && m.echo === say) { port.onMessage.removeListener(onMessage); resolve(m); } };
      port.onMessage.addListener(onMessage);
      port.postMessage({ say });
    }), ms, 'port ' + name);
  };
  globalThis.__stress = {
    ping: (n, ms) => deadline(chrome.runtime.sendMessage({ type: 'ping', n }), ms, 'ping'),
    storage: (n, ms) => deadline(chrome.runtime.sendMessage({ type: 'storage', n }), ms, 'storage'),
    open,
    echo,
    openAndEcho: (name, say, ms) => { open(name); return echo(name, say, ms); },
    close: (name) => { if (ports[name]) { ports[name].disconnect(); delete ports[name]; } return true; },
    set: (items, ms) => deadline(chrome.storage.local.set(items).then(() => true), ms, 'storage.set'),
    closeAll: () => { for (const k of Object.keys(ports)) { ports[k].disconnect(); delete ports[k]; } return true; },
  };
  document.documentElement.setAttribute('data-stress-cs', 'ready');
})();
