// Test 4: Toolbar → Popup → current tab.
(async () => {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  const stored = await chrome.storage.local.get('selftest');
  document.getElementById('out').textContent = tab ? ('Active tab: ' + tab.title) : 'No tab';
  await chrome.storage.local.set({ popupSawTab: tab ? tab.id : -1, popupSawStorage: !!stored.selftest });
})();
