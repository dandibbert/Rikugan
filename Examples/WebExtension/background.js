const api = typeof browser !== 'undefined' ? browser : chrome;

function callWith(target, name, args) {
  return new Promise((resolve, reject) => {
    const fn = target && target[name];
    if (typeof fn !== 'function') { reject(new Error('missing api')); return; }
    let settled = false;
    function done(value) {
      if (settled) return;
      settled = true;
      resolve(value);
    }
    let result;
    try { result = fn.apply(target, args); }
    catch (error) { reject(error); return; }
    if (result && typeof result.then === 'function') { result.then(done, reject); return; }
    if (result !== undefined) { done(result); return; }
    try { fn.apply(target, args.concat([value => done(value)])); }
    catch (error) { reject(error); }
  });
}

function deadline(work, ms) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('timeout')), ms);
    Promise.resolve(work).then(value => { clearTimeout(timer); resolve(value); }, error => { clearTimeout(timer); reject(error); });
  });
}

let visits = 0;
try {
  const storage = api.storage && api.storage.local;
  const pending = storage && typeof storage.get === 'function' ? storage.get.call(storage, 'visits') : null;
  if (pending && typeof pending.then === 'function') pending.then(result => { visits = (result && result.visits) || 0; }, () => {});
} catch (error) {}

api.runtime.onMessage.addListener((message, sender) => {
  if (message && message.source === 'rikugan-bg-probe') return Promise.resolve({ ready: true });
  if (!message || message.type !== 'rikugan-probe') return;
  visits += 1;
  const count = visits;
  const payload = { ok: true, visits: count };
  try {
    const storage = api.storage && api.storage.local;
    const wrote = storage && typeof storage.set === 'function' ? storage.set.call(storage, { visits: count }) : null;
    if (wrote && typeof wrote.catch === 'function') wrote.catch(() => {});
  } catch (error) {}
  const tabId = sender && sender.tab && sender.tab.id;
  const target = {};
  if (tabId != null) target.tabId = tabId;
  const scripting = api.scripting;
  const notifications = api.notifications;
  const tabs = api.tabs;
  const located = tabId != null
    ? Promise.resolve(target)
    : deadline(callWith(tabs, 'query', [{ active: true, currentWindow: true }]), 2000).then(list => {
      const id = list && list[0] && list[0].id;
      if (id != null) target.tabId = id;
      return target;
    }).catch(() => target);
  located.then(() => deadline(callWith(scripting, 'insertCSS', [{ target, css: '#rikugan-scripting-result{outline:1px solid transparent}' }]), 2000))
    .then(() => deadline(callWith(scripting, 'executeScript', [{
      target,
      func: function () {
        var node = document.getElementById('rikugan-scripting-result') || document.createElement('div');
        node.id = 'rikugan-scripting-result';
        node.textContent = '脚本注入成功';
        (document.body || document.documentElement).prepend(node);
      }
    }]), 2000))
    .catch(() => {})
    .then(() => deadline(callWith(notifications, 'create', ['rikugan-demo', { title: 'Rikugan', message: '通知已创建' }]), 2000))
    .then(() => deadline(callWith(notifications, 'getAll', []), 2000))
    .then(all => {
      if (!all || !all['rikugan-demo']) return null;
      return deadline(callWith(scripting, 'executeScript', [{
        target,
        func: function () {
          var node = document.getElementById('rikugan-notification-result') || document.createElement('div');
          node.id = 'rikugan-notification-result';
          node.textContent = '通知已创建';
          (document.body || document.documentElement).prepend(node);
        }
      }]), 2000);
    })
    .catch(() => {});
  return Promise.resolve(payload);
});
