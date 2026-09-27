(() => {
  const h = window.webkit.messageHandlers.rikugan;
  const post = (m) => h.postMessage(m).then((v) => 'resolved:' + JSON.stringify(v), (e) => 'rejected:' + (e && e.message || e));
  globalThis.__attackB = async (p) => {
    const R = {};
    R.storageAsAContent = await post({ ch: 'chrome', ext: p.extA, ctx: 'content', api: 'storage.get', args: {} });
    R.storageAsAPage = await post({ ch: 'chrome', ext: p.extA, ctx: 'page', api: 'storage.get', args: {} });
    R.messageAsA = await post({ ch: 'chrome', ext: p.extA, ctx: 'content', api: 'runtime.sendMessage', args: { message: { type: 'evil' } } });
    R.tabsAsABackground = await post({ ch: 'chrome', ext: p.extA, ctx: 'background', api: 'tabs.query', args: { args: [{}] } });
    R.portPostClaimingA = await post({ ch: 'chrome', ext: p.extA, ctx: 'content', api: 'port.post', args: { portId: p.aPort, message: { say: 'evil-claiming-a' } } });
    R.portPostIntoA = await post({ ch: 'chrome', ext: p.extB, ctx: 'content', api: 'port.post', args: { portId: p.aPort, message: { say: 'evil-from-b' } } });
    R.portDisconnectA = await post({ ch: 'chrome', ext: p.extB, ctx: 'content', api: 'port.disconnect', args: { portId: p.aPort } });
    R.gmAsVictim = await post({ ch: 'gm', sid: p.sid, op: 'getAll', args: null });
    R.ownStorage = await chrome.storage.local.get(null).then((v) => 'resolved:' + JSON.stringify(v), (e) => 'rejected:' + e.message);
    return R;
  };
  document.documentElement.setAttribute('data-b-ready', '1');
})();
