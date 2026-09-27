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

// Full local compatibility probe: actual effects, not merely installing a ZIP.
if (location.hostname === '127.0.0.1') {
  (async () => {
    const status = document.createElement('p'); status.id = 'rikugan-full-suite';
    document.body.appendChild(status);
    try {
      if (!globalThis.__rikuganDocumentStart || document.readyState === 'loading') throw new Error('run_at document_start/end');
      const marker = document.createElement('div'); marker.className = 'rikugan-runtime-css-probe'; document.body.appendChild(marker);
      const css = getComputedStyle(marker).borderTopWidth === '7px'; marker.remove();
      if (!css) throw new Error('content CSS');
      const api = await browser.runtime.sendMessage({type: 'rikugan-api-probe'});
      if (!api.allowed || api.denied || !api.scripting || document.documentElement.dataset.rikuganScripting !== 'passed') throw new Error('permissions/scripting: ' + JSON.stringify(api));
      await new Promise((resolve, reject) => {
        const port = browser.runtime.connect({name: 'rikugan-port'});
        const timer = setTimeout(() => { port.disconnect(); reject(new Error('Port timed out')); }, 10000);
        port.onMessage.addListener(message => { clearTimeout(timer); port.disconnect(); message.echo === 'hello' ? resolve() : reject(new Error('Port reply')); });
        port.postMessage({value: 'hello'});
      });
      const control = await fetch('/__echo');
      if (!control.ok) throw new Error('DNR control resource');
      const blocked = await fetch('/extension-blocked').then(() => false, () => true);
      if (!blocked) throw new Error('DNR did not block the test request');
      status.textContent = '扩展完整自检通过';
    } catch (error) { status.textContent = '扩展完整自检失败：' + String(error); }
  })();
}
