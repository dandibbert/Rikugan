const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync('Rikugan/Resources/PageTools.js', 'utf8');
const { classify, options, redirectScriptlets } = require('./adblock_subset.cjs');

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
  URL,
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

const css = sandbox.RikuganPageTools.darkCSS;
assert.equal(typeof css, 'string');
assert.equal(css.includes('invert('), false);
assert.ok(css.includes('#e8e8e8'));
const textRule = css.split('img,video,picture,canvas,svg')[0];
assert.ok(textRule.includes('#e8e8e8'));
assert.equal(textRule.includes('img,'), false);
assert.ok(css.includes('filter:none'));

const playlist = [
  '#EXTM3U',
  '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.4d401e"',
  'low/index.m3u8',
  '#EXT-X-STREAM-INF:BANDWIDTH=1400000,RESOLUTION=1280x720',
  'hi/index.m3u8'
].join('\n');
const variants = sandbox.RikuganPageTools.parseM3U8(playlist, 'https://cdn.example/video/master.m3u8');
assert.equal(variants.length, 2);
assert.equal(variants[0].bandwidth, 800000);
assert.equal(variants[0].width, 640);
assert.equal(variants[0].height, 360);
assert.equal(variants[0].url, 'https://cdn.example/video/low/index.m3u8');
assert.equal(variants[1].url, 'https://cdn.example/video/hi/index.m3u8');
const dash = sandbox.RikuganPageTools.parseMPD(
  '<MPD><Representation bandwidth="900000" width="640" height="360"><BaseURL>v.mp4</BaseURL></Representation></MPD>',
  'https://cdn.example/dash/'
);
assert.equal(dash.length, 1);
assert.equal(dash[0].url, 'https://cdn.example/dash/v.mp4');
assert.equal(dash[0].kind, 'dash');

let marked = false;
sandbox.document = {
  body: {},
  createTreeWalker() {
    const nodes = [{ nodeType: 3, nodeValue: 'Cats and cats.' }];
    let index = 0;
    return { nextNode() { return index < nodes.length ? nodes[index++] : null; } };
  },
  querySelectorAll() { marked = true; return []; }
};
assert.equal(sandbox.RikuganPageTools.countMatches('cats'), 2);
assert.equal(marked, false);
assert.equal(sandbox.RikuganPageTools.countMatches(''), 0);

assert.equal(classify('||ads.example^'), 'block');
assert.equal(classify('@@||ads.example^'), 'allow');
assert.equal(classify('||ads.example^$script,third-party'), 'block');
assert.deepEqual(options('||ads.example^$script,third-party').types, ['script']);
assert.equal(options('||ads.example^$script,third-party').thirdParty, true);
assert.deepEqual(options('||ads.example^$domain=news.example|~ok.example').domains, ['news.example', '~ok.example']);
assert.equal(classify('example.com##.ad'), 'cosmetic');
assert.equal(classify('example.com#$#body{color:red}'), 'css');
assert.equal(classify('example.com#?#div:has(.ad)'), 'cosmetic');
assert.equal(classify('example.com#?#div:has-text(Sponsored)'), 'procedural');
assert.equal(classify('example.com#?#:xpath(//div[@class="ad"])'), 'procedural');
assert.equal(classify('example.com#?#.ad:matches-css(display, none)'), 'procedural');
assert.equal(classify('example.com#?#.ad:upward(2)'), 'procedural');
assert.equal(classify('example.com#?#.ad:remove()'), 'procedural');
assert.equal(classify('example.com#?#.ad:style(color: red)'), 'procedural');
assert.equal(classify('#%#scriptlet'), 'drop');
assert.equal(classify("example.com#%#//scriptlet('abort-on-property-read', 'alert')"), 'scriptlet');
assert.equal(classify('example.com##+js(set-constant, canRunAds, false)'), 'scriptlet');
assert.equal(classify('||ads.example^$redirect=noopjs'), 'block');
const noopStubs = redirectScriptlets('||ads.example^$redirect=noopjs');
assert.equal(noopStubs[0].name, 'set-constant');
assert.deepEqual(noopStubs[0].args, ['__rgRedirect.noopjs', 'noopFunc']);
assert.equal(noopStubs[1].name, 'prevent-fetch');
assert.deepEqual(noopStubs[1].args, ['ads.example']);
assert.equal(redirectScriptlets('||blank.test^$redirect=empty')[0].args[0], '__rgRedirect.empty');
assert.equal(redirectScriptlets('||pixel.test^$redirect=1x1')[0].args[0], '__rgRedirect.pixel');
assert.deepEqual(redirectScriptlets('||ads.example^$redirect=googletag'), []);
assert.equal(classify('||news.example^$removeparam=utm_source'), 'removeparam');
assert.equal(classify("||news.example^$csp=script-src 'none'"), 'csp');
assert.equal(classify('||news.example^$replace=/a/b/'), 'replace');
const html = { outerHTML: '<html><body>hello ad</body></html>' };
sandbox.document = { documentElement: html };
sandbox.RikuganPageTools.applyReplace([{ needle: 'news.example', regex: 'hello ad', replacement: 'hello', flags: '' }], 'https://news.example/a');
assert.equal(html.outerHTML, '<html><body>hello</body></html>');
sandbox.RikuganPageTools.applyReplace([{ needle: 'other.test', regex: 'hello', replacement: 'nope', flags: '' }], 'https://news.example/a');
assert.equal(html.outerHTML, '<html><body>hello</body></html>');
function box(value) { return { then(onOk) { return onOk(value); } }; }
sandbox.__rgReplaceHook = undefined;
sandbox.window.__rgReplaceHook = undefined;
sandbox.fetch = () => box({ status: 200, headers: { get() { return 'text/plain'; } }, text: () => box('ad-code https://cdn.example/ad.js') });
sandbox.window.fetch = sandbox.fetch;
sandbox.Response = function Response(body) { this.body = body; };
sandbox.window.Response = sandbox.Response;
sandbox.RikuganPageTools.applyReplace([{ needle: 'cdn.example', regex: 'ad-code', replacement: 'clean', flags: 'g' }], 'https://cdn.example/ad.js');
assert.equal(sandbox.fetch('https://cdn.example/ad.js').body, 'clean https://cdn.example/ad.js');
sandbox.location = { hostname: 'news.example' };
sandbox.JSON = { parse: JSON.parse, stringify: JSON.stringify };
sandbox.Promise = Promise;
let fetched = [];
sandbox.fetch = url => { fetched.push(url); return { ok: true }; };
function XHR() {}
XHR.prototype.open = function (method, url) { this.url = url; };
XHR.prototype.send = function () { this.sent = true; };
sandbox.XMLHttpRequest = XHR;
sandbox.RikuganPageTools.applyScriptlets([
  { domains: ['news.example'], name: 'set-constant', args: ['canRunAds', 'false'] },
  { domains: ['other.test'], name: 'set-constant', args: ['skipped', 'true'] },
  { domains: [], name: 'abort-on-property-read', args: ['pageAd'] },
  { domains: [], name: 'abort-on-property-write', args: ['adConfig'] },
  { domains: [], name: 'prevent-fetch', args: ['/ads/'] },
  { domains: [], name: 'prevent-xhr', args: ['track'] },
  { domains: [], name: 'json-prune', args: ['ad'] }
]);
assert.equal(sandbox.canRunAds, false);
assert.equal(sandbox.skipped, undefined);
assert.throws(() => sandbox.pageAd);
assert.throws(() => { sandbox.adConfig = 1; });
const blockedFetch = sandbox.fetch('https://cdn.example/ads/a.js');
blockedFetch.catch(() => {});
assert.equal(typeof blockedFetch.then, 'function');
assert.deepEqual(fetched, []);
sandbox.fetch('https://cdn.example/ok.js');
assert.deepEqual(fetched, ['https://cdn.example/ok.js']);
const blockedXHR = new sandbox.XMLHttpRequest();
blockedXHR.open('GET', 'https://t.example/track');
blockedXHR.send();
assert.equal(blockedXHR.sent, undefined);
const openXHR = new sandbox.XMLHttpRequest();
openXHR.open('GET', 'https://t.example/ok');
openXHR.send();
assert.equal(openXHR.sent, true);
const pruned = sandbox.JSON.parse('{"ad":1,"title":"x","nested":{"ad":2}}');
assert.equal(pruned.ad, undefined);
assert.equal(pruned.title, 'x');
assert.equal(pruned.nested.ad, undefined);
sandbox.RikuganPageTools.applyScriptlets([
  { domains: ['news.example'], name: 'set-constant', args: ['__rgRedirect.noopjs', 'noopFunc'] },
  { domains: ['news.example'], name: 'set-constant', args: ['__rgRedirect.empty', "''"] },
  { domains: ['news.example'], name: 'set-constant', args: ['__rgRedirect.pixel', 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7'] }
]);
assert.equal(typeof sandbox.__rgRedirect.noopjs, 'function');
assert.equal(sandbox.__rgRedirect.noopjs(), undefined);
assert.equal(sandbox.__rgRedirect.empty, '');
assert.match(sandbox.__rgRedirect.pixel, /^data:image\/gif/);
assert.equal(classify('example.com#@#.ad'), 'unhide');

sandbox.performance = { getEntriesByType(type) { return type === 'navigation' ? [{ name: 'https://cdn.example/clip.mp4', transferSize: 9 }] : []; } };
sandbox.document = { querySelectorAll() { return []; } };
const navigated = sandbox.RikuganPageTools.collectMedia();
assert.equal(navigated.some(item => item.url === 'https://cdn.example/clip.mp4' && item.kind === 'video' && item.size === 9), true);

console.log('PASS: page tools selector, dark CSS, playlists, find count, adblock subset');
