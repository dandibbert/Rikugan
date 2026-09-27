const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync('Rikugan/Resources/PageTools.js', 'utf8');

function element(tag, props = {}) {
  return {
    nodeType: 1,
    tagName: tag.toUpperCase(),
    id: props.id || '',
    classList: props.classes || [],
    parentElement: props.parent || null,
    children: props.children || [],
    style: {}
  };
}

const child = element('span', { id: 'title', classes: ['headline'] });
const parent = element('div', { classes: ['wrap'], children: [child] });
child.parentElement = parent;
const paragraph = element('p', { classes: ['lead'] });
const body = element('body', { children: [paragraph] });
paragraph.parentElement = body;

const sandbox = {
  console,
  document: null,
  window: { fetch() { return Promise.resolve(); } }
};
sandbox.globalThis = sandbox;
vm.runInNewContext(source, sandbox, { filename: 'PageTools.js' });
assert.equal(typeof sandbox.RikuganPageTools.selector, 'function');
assert.equal(sandbox.RikuganPageTools.selector(child), '#title');
assert.equal(sandbox.RikuganPageTools.selector(paragraph), 'body > p.lead');
assert.equal(sandbox.RikuganPageTools.selector({ nodeType: 3 }), '');
sandbox.RikuganPageTools.setAppearance('off');
sandbox.RikuganPageTools.setFont('');
assert.equal(sandbox.RikuganPageTools.extractArticle(), null);
const found = sandbox.RikuganPageTools.collectMedia();
assert.ok(Array.isArray(found));
console.log('PASS: page tools selector, appearance no-ops, and media collector');
