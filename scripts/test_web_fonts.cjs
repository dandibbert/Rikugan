const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
function element(text, font = 'Arial', protectedNode = false) {
  const values = new Map();
  return {nodeType: 1, tagName: 'SPAN', isConnected: true, textContent: text, font,
    childNodes: [{nodeType: 3, nodeValue: text}], querySelectorAll: () => [],
    closest: () => protectedNode ? {} : null, querySelector: () => null,
    style: {getPropertyValue: key => values.get(key)?.[0] || '', getPropertyPriority: key => values.get(key)?.[1] || '',
      setProperty: (key, value, priority) => values.set(key, [value, priority]), removeProperty: key => values.delete(key)}};
}
const text = element('正文'), icon = element('check', 'Material Icons'), tagged = element('star', 'Arial', true), pua = element('\uE011');
const body = element(''); body.querySelectorAll = () => [text, icon, tagged, pua];
const document = {body, documentElement: body, getElementById: () => null};
const sandbox = {document, getComputedStyle: element => ({fontFamily: element.font}), MutationObserver: class {observe() {} disconnect() {}}, setTimeout};
vm.runInNewContext(fs.readFileSync('Rikugan/Resources/WebFontEngine.js', 'utf8'), sandbox);
sandbox.RikuganWebFonts.apply('Custom Font');
assert.match(text.style.getPropertyValue('font-family'), /Custom Font/);
for (const element of [icon, tagged, pua]) assert.equal(element.style.getPropertyValue('font-family'), '');
sandbox.RikuganWebFonts.apply('');
assert.equal(text.style.getPropertyValue('font-family'), '');
console.log('PASS: text font replacement, icon/symbol exclusion and reversible disabling');
