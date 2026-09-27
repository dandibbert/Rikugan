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

const inputs = Object.fromEntries(['username','password','name','email','phone','address','cardNumber','cardName'].map(key => [key, {
  value: '', focus() {}, dispatchEvent() {}
}]));
const selectorMap = [
  ['autocomplete="username"', 'username'], ['type="password"', 'password'], ['autocomplete="name"', 'name'],
  ['autocomplete="email"', 'email'], ['autocomplete="tel"', 'phone'], ['autocomplete="street-address"', 'address'],
  ['autocomplete="cc-number"', 'cardNumber'], ['autocomplete="cc-name"', 'cardName']
];
sandbox.document = { querySelector(selector) { const match = selectorMap.find(([needle]) => selector.includes(needle)); return match ? inputs[match[1]] : null; } };
sandbox.Event = class Event { constructor(type) { this.type = type; } };
const fill = sandbox.RikuganPageTools.fill({username:'user',password:'pass',name:'Name',email:'mail@example.com',phone:'123',address:'Road',cardNumber:'4111',cardName:'Card Name'});
assert.deepEqual(JSON.parse(JSON.stringify(fill)), {username:true,password:true,name:true,email:true,phone:true,address:true,cardNumber:true,cardName:true});
assert.deepEqual(Object.fromEntries(Object.entries(inputs).map(([key, input]) => [key, input.value])), {username:'user',password:'pass',name:'Name',email:'mail@example.com',phone:'123',address:'Road',cardNumber:'4111',cardName:'Card Name'});

const sent = [];
const underlying = element('div', {id: 'ad-slot'}); underlying.style = {outline: ''};
const made = [];
function domElement(tag) {
  const listeners = {};
  const value = element(tag); value.style = {}; value.dataset = {}; value.listeners = listeners; value.removed = false;
  value.addEventListener = (name, handler) => { listeners[name] = handler; };
  value.appendChild = child => { value.children.push(child); child.parentElement = value; };
  value.append = (...children) => children.forEach(value.appendChild);
  value.remove = () => { value.removed = true; };
  made.push(value); return value;
}
const pickerBody = domElement('body');
sandbox.document = {
  body: pickerBody,
  createElement: domElement,
  getElementById() { return null; },
  elementFromPoint() { return underlying; }
};
sandbox.webkit = {messageHandlers: {rikuganPage: {postMessage(message) { sent.push(message); }}}};
assert.equal(sandbox.RikuganPageTools.startPicker(), true);
const veil = made.find(item => item.id === 'rikugan-picker');
assert.ok(veil);
veil.listeners.click({clientX: 12, clientY: 20, preventDefault() {}});
assert.deepEqual(JSON.parse(JSON.stringify(sent)), [{action:'picker', selector:'#ad-slot', label:'div'}]);
console.log('PASS: page tools selector, touch-safe direct-click element picker, media collector and password/identity/payment autofill mapping');
