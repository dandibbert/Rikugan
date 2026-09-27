Promise.all([browser.tabs.query({active: true, currentWindow: true}), browser.storage.local.get('visits')]).then(([tabs, storage]) => {
  document.querySelector('#status').textContent = '弹窗运行成功';
  document.querySelector('#tab').textContent = '当前标签页：' + (tabs[0]?.url || tabs[0]?.title || '(空白页)');
  document.querySelector('#storage').textContent = '扩展后台计数：' + (storage.visits || 0);
}).catch(error => { document.querySelector('#status').textContent = String(error); });

