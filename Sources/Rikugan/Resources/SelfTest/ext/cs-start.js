// Test 1: document_start content script.
document.documentElement.setAttribute('data-cs-start', document.body ? 'late' : 'ok');
