browser.runtime.onMessage.addListener((message, sender, reply) => {
  if (message.type !== 'rikugan-probe') return false;
  const tabId = sender.tab && sender.tab.id;
  const target = {};
  if (tabId != null) target.tabId = tabId;
  const scripting = (browser.scripting || chrome.scripting);
  const notifications = (browser.notifications || chrome.notifications);
  browser.storage.local.get('visits').then(result => {
    const visits = (result.visits || 0) + 1;
    return browser.storage.local.set({visits}).then(() => visits);
  }).then(async visits => {
    let scriptingOk = false;
    let notificationOk = false;
    try {
      await scripting.insertCSS({ target, css: '#rikugan-scripting-result{outline:1px solid transparent}' });
      await scripting.executeScript({
        target,
        func: function () {
          var node = document.getElementById('rikugan-scripting-result') || document.createElement('div');
          node.id = 'rikugan-scripting-result';
          node.textContent = '脚本注入成功';
          (document.body || document.documentElement).prepend(node);
        }
      });
      scriptingOk = true;
    } catch (error) { scriptingOk = false; }
    try {
      await notifications.create('rikugan-demo', { title: 'Rikugan', message: '通知已创建' });
      const all = await notifications.getAll();
      notificationOk = !!(all && all['rikugan-demo']);
    } catch (error) { notificationOk = false; }
    reply({ ok: true, visits, scripting: scriptingOk, notification: notificationOk });
  }).catch(error => reply({ ok: false, error: String(error) }));
  return true;
});
