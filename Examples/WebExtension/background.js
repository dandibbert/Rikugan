browser.runtime.onMessage.addListener((message, sender, reply) => {
  if (message.type !== 'rikugan-probe') return false;
  browser.storage.local.get('visits').then(result => {
    const visits = (result.visits || 0) + 1;
    return browser.storage.local.set({visits}).then(() => reply({ok: true, visits}));
  }).catch(error => reply({ok: false, error: String(error)}));
  return true;
});
