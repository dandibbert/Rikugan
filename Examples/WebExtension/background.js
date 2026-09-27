browser.runtime.onMessage.addListener((message, sender, reply) => {
  if (message.type === 'rikugan-api-probe') {
    Promise.all([
      browser.permissions.contains({origins: ['http://127.0.0.1/*']}),
      browser.permissions.contains({origins: ['http://localhost/*']}),
      browser.scripting.executeScript({target: {tabId: sender.tab.id}, func: () => {
        document.documentElement.dataset.rikuganScripting = 'passed'; return 'executed';
      }})
    ]).then(([allowed, denied, result]) => reply({allowed, denied, scripting: result.some(item => item.result === 'executed')}))
      .catch(error => reply({error: String(error)}));
    return true;
  }
  if (message.type !== 'rikugan-probe') return false;
  browser.storage.local.get('visits').then(result => {
    const visits = (result.visits || 0) + 1;
    return browser.storage.local.set({visits}).then(() => reply({ok: true, visits}));
  }).catch(error => reply({ok: false, error: String(error)}));
  return true;
});
browser.runtime.onConnect.addListener(port => {
  if (port.name === 'rikugan-port') port.onMessage.addListener(message => port.postMessage({echo: message.value}));
});
