const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const template = fs.readFileSync('Rikugan/Resources/UserscriptRuntime.js', 'utf8');
const tick = () => new Promise(resolve => setImmediate(resolve));
const response = text => ({status: 200, statusText: 'OK', responseText: text, responseBase64: Buffer.from(text).toString('base64'), responseHeaders: 'Content-Type: text/plain', readyState: 4});
function runtime(transport) {
  let context;
  const config = {id: 'xhr', name: 'XHR', isolated: true, handler: 'test', matches: ['https://example.com/*'], includes: [], excludes: [], excludeMatches: [], grants: ['GM.xmlHttpRequest', 'GM_xmlhttpRequest'], runAt: 'document-end', storage: {}};
  const sandbox = {URL, URLSearchParams, Blob, FormData, TextEncoder, TextDecoder, atob, btoa, setTimeout, clearTimeout, console,
    location: new URL('https://example.com/'), document: {body: {}}, window: {webkit: {messageHandlers: {test: {postMessage: body => transport(body, context)}}}}};
  context = vm.createContext(sandbox);
  new vm.Script(template.replace('/*__CONFIG__*/', JSON.stringify(config)).replace('/*__SOURCE__*/', 'globalThis.xhr = GM.xmlHttpRequest; globalThis.legacy = GM_xmlhttpRequest;')).runInContext(context);
  return context;
}
(async () => {
  const calls = [], states = [], events = [];
  const page = runtime((body, context) => {
    calls.push(body);
    context.__rikuganXHRProgress(body.client, body.args.id, {readyState: 2, status: 200});
    context.__rikuganXHRProgress(body.client, body.args.id, {readyState: 3, status: 200, loaded: 4, total: 4});
    return Promise.resolve(response('{"ok":true}'));
  });
  const result = await page.xhr({url: '/echo', method: 'POST', data: new URLSearchParams({q: 'a+b & c'}), responseType: 'json', context: 'token',
    onreadystatechange: value => states.push(value.readyState), onprogress: value => events.push(value.loaded)});
  assert.equal(result.response.ok, true); assert.equal(result.context, 'token');
  assert.deepEqual(states, [1, 2, 3, 4]); assert.deepEqual(events, [4]);
  assert.equal(calls[0].args.data, 'q=a%2Bb+%26+c');
  assert.match(calls[0].args.headers['Content-Type'], /x-www-form-urlencoded/);
  const form = new FormData(); form.append('field', 'hello'); form.append('file', new Blob([Uint8Array.of(0, 1, 255)], {type: 'application/octet-stream'}), 'file.bin');
  await page.xhr({url: '/echo', data: form});
  const multipart = calls.at(-1).args;
  const bytes = Buffer.from(multipart.dataBase64, 'base64');
  assert.match(multipart.headers['Content-Type'], /multipart\/form-data; boundary=Rikugan-/);
  assert.ok(bytes.includes(Buffer.from('name="field"\r\n\r\nhello'))); assert.ok(bytes.includes(Buffer.from([0, 1, 255])));
  await page.xhr({url: '/echo', data: Uint8Array.of(3, 2, 1)});
  assert.deepEqual(Buffer.from(calls.at(-1).args.dataBase64, 'base64'), Buffer.from([3, 2, 1]));
  await page.xhr({url: '/echo', headers: {'X-Count': 42}});
  assert.equal(calls.at(-1).args.headers['X-Count'], '42');

  let finishNative, aborts = 0, loads = 0, callbackAborts = 0;
  const abortPage = runtime(body => {
    if (body.operation === 'abortRequest') { aborts++; return Promise.resolve(true); }
    return new Promise(resolve => { finishNative = resolve; });
  });
  const request = abortPage.xhr({url: '/slow', onload: () => loads++, onabort: () => callbackAborts++});
  const rejected = assert.rejects(request, error => error.name === 'AbortError');
  await tick(); request.abort(); request.abort(); await rejected;
  finishNative(response('late')); await tick();
  assert.equal(aborts, 1); assert.equal(callbackAborts, 1); assert.equal(loads, 0);
  let timeouts = 0, errors = 0;
  const timed = abortPage.xhr({url: '/slow', timeout: 10, ontimeout: () => timeouts++, onerror: () => errors++});
  await assert.rejects(timed, error => error.name === 'TimeoutError');
  assert.equal(timeouts, 1); assert.equal(errors, 0); assert.equal(aborts, 2);
  await assert.rejects(page.xhr({url: '/echo', synchronous: true}), /Unsupported API/);
  await assert.rejects(page.xhr({url: '/echo', responseType: 'stream'}), /Unsupported API/);
  await assert.rejects(page.xhr({url: '/echo', data: new Blob([new Uint8Array(2000001)])}), /2 MB/);
  console.log('PASS: GM XHR states/progress, JSON, multipart and binary upload, real abort command, timeout and explicit unsupported options');
})().catch(error => { console.error(error); process.exitCode = 1; });
