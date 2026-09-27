browser.runtime.sendMessage({type: 'rikugan-probe'}).then(result => {
  const panel = document.createElement('section');
  panel.id = 'rikugan-extension-result';
  panel.style.cssText = 'padding:18px;margin:12px;background:#e5f7eb;color:#123e29;font:16px system-ui;border-radius:14px';
  const title = document.createElement('strong');
  title.textContent = result?.ok ? '扩展运行成功' : '扩展后台异常';
  let count = result?.visits ?? result?.error;
  if (count == null) {
    try { count = JSON.stringify(result); } catch (error) { count = String(result); }
  }
  const detail = document.createElement('div');
  detail.textContent = '后台通信与扩展存储计数：' + (count ?? '?');
  panel.append(title, detail);
  if (result?.notification) {
    const note = document.createElement('div');
    note.id = 'rikugan-notification-result';
    note.textContent = '通知已创建';
    panel.append(note);
  }
  document.body.prepend(panel);
}).catch(error => { console.error('Rikugan Demo', error); });
