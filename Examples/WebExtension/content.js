browser.runtime.sendMessage({type: 'rikugan-probe'}).then(result => {
  const panel = document.createElement('section');
  panel.id = 'rikugan-extension-result';
  panel.style.cssText = 'padding:18px;margin:12px;background:#e5f7eb;color:#123e29;font:16px system-ui;border-radius:14px';
  const title = document.createElement('strong');
  title.textContent = result?.ok ? '扩展运行成功' : '扩展后台异常';
  const detail = document.createElement('div');
  detail.textContent = '后台通信与扩展存储计数：' + (result?.visits ?? result?.error ?? '?');
  panel.append(title, detail); document.body.prepend(panel);
}).catch(error => {
  console.error('Rikugan Demo', error);
  const panel = document.createElement('p');
  panel.id = 'rikugan-extension-error';
  panel.textContent = '扩展错误：' + String(error);
  document.body.prepend(panel);
});
