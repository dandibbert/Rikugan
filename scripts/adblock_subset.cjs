'use strict';

const scriptlets = new Set(['abort-on-property-read', 'abort-on-property-write', 'json-prune', 'set-constant', 'prevent-fetch', 'prevent-xhr']);

function scriptletName(line) {
  const body = line.includes('#%#') ? line.split('#%#').slice(1).join('#%#') : (line.split('##+js(')[1] || '');
  const text = body.replace(/^\/\/scriptlet\(/, '').replace(/\)$/, '');
  const name = text.split(',')[0].replace(/['"\s]/g, '');
  return scriptlets.has(name) ? name : '';
}

function modifierTokens(line) {
  const dollars = [];
  for (let i = 0; i < line.length; i++) {
    if (line[i] !== '$') continue;
    let slashes = 0;
    for (let j = i - 1; j >= 0 && line[j] === '\\'; j--) slashes++;
    if (slashes % 2 === 0) dollars.push(i);
  }
  const known = ['redirect', 'redirect-rule', 'removeparam', 'csp', 'replace', 'jsonprune'];
  for (let n = dollars.length - 1; n >= 0; n--) {
    const index = dollars[n];
    if (index <= 0) continue;
    const head = line.slice(0, index);
    const mods = line.slice(index + 1);
    if (head.startsWith('/') && head.endsWith('/')) return null;
    if (!mods) continue;
    const tokens = mods.split(',');
    const plausible = tokens.every(token => {
      if (known.some(name => token === name || token.startsWith(name + '='))) return true;
      if (!token || token.includes(' ') || token.includes('$') || !/^[A-Za-z~]/.test(token)) return false;
      return /^[A-Za-z0-9~_.=|*-]+$/.test(token);
    });
    if (plausible) return tokens;
  }
  return null;
}

function classify(raw) {
  const line = String(raw || '').trim();
  if (!line || line.startsWith('!') || line.startsWith('[')) return 'drop';
  if (line.includes('#%#') || line.includes('##+js(')) return scriptletName(line) ? 'scriptlet' : 'drop';
  if (line.includes('#@#') || line.includes('#@?#') || line.includes('#@$#')) return 'unhide';
  if (line.includes('#?#')) {
    const selector = line.split('#?#')[1] || '';
    if (/:(?:has-text|contains|-abp-contains)\(/.test(selector)) return 'procedural';
    if (/:(?:has-text|contains|-abp-contains|xpath|matches-css|upward|remove|style)\(/.test(selector)) return 'procedural';
    return 'cosmetic';
  }
  if (line.includes('#$#')) return /\{/.test(line) && !/url\(|@import|javascript:/i.test(line) ? 'css' : 'drop';
  if (line.includes('##')) return 'cosmetic';
  if (line.startsWith('@@')) return 'allow';
  const mods = modifierTokens(line);
  if (mods) {
    if (mods.some(token => token === 'jsonprune' || token.startsWith('jsonprune='))) return 'jsonprune';
    if (mods.some(token => token === 'replace' || token.startsWith('replace='))) return 'replace';
    if (mods.some(token => token === 'removeparam' || token.startsWith('removeparam='))) return 'removeparam';
    if (mods.some(token => token === 'csp' || token.startsWith('csp='))) return 'csp';
    if (mods.some(token => token === 'redirect' || token.startsWith('redirect=') || token === 'redirect-rule' || token.startsWith('redirect-rule='))) return 'block';
  }
  return 'block';
}

function options(raw) {
  const line = String(raw);
  const dollar = line.lastIndexOf('$');
  if (dollar < 0) return {};
  const mods = line.slice(dollar + 1).split(',');
  const out = { types: [], thirdParty: null, domains: [] };
  for (const token of mods) {
    if (token === 'third-party') out.thirdParty = true;
    else if (token === '~third-party') out.thirdParty = false;
    else if (['script', 'image', 'stylesheet', 'media', 'font'].includes(token)) out.types.push(token);
    else if (token.startsWith('domain=')) out.domains.push(...token.slice(7).split('|'));
  }
  return out;
}

function redirectScriptlets(raw) {
  const line = String(raw || '');
  const dollar = line.lastIndexOf('$');
  if (dollar < 0) return [];
  let resource = '';
  for (const token of line.slice(dollar + 1).split(',')) {
    if (token === 'redirect' || token === 'redirect-rule') resource = resource || 'empty';
    else if (token.startsWith('redirect=') || token.startsWith('redirect-rule=')) resource = token.slice(token.indexOf('=') + 1);
  }
  if (!resource) return [];
  const host = ((line.match(/\|\|([^/^$]+)/) || [])[1] || '').replace(/^\*\./, '');
  const domains = host ? [host] : [];
  const key = resource.toLowerCase();
  const pixel = 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';
  let constant = null;
  if (key === 'noopjs' || key === 'noop.js') constant = ['__rgRedirect.noopjs', 'noopFunc'];
  else if (key === 'empty') constant = ['__rgRedirect.empty', "''"];
  else if (key === '1x1' || key === '1x1.gif') constant = ['__rgRedirect.pixel', pixel];
  if (!constant) return [];
  const rows = [{ domains, name: 'set-constant', args: constant }];
  if (host) rows.push({ domains, name: 'prevent-fetch', args: [host] });
  return rows;
}

function filterBody(raw) {
  let body = String(raw || '').trim();
  if (body.startsWith('@@')) body = body.slice(2);
  const tokens = modifierTokens(body);
  if (!tokens) return body;
  const tail = '$' + tokens.join(',');
  const index = body.lastIndexOf(tail);
  return index > 0 ? body.slice(0, index) : body;
}

function typeName(token) {
  switch (token) {
    case 'script': return 'script';
    case 'image': return 'image';
    case 'stylesheet': return 'style-sheet';
    case 'xmlhttprequest':
    case 'xhr':
    case 'other':
    case 'ping':
    case 'websocket': return 'raw';
    case 'media': return 'media';
    case 'font': return 'font';
    case 'document':
    case 'subdocument': return 'document';
    default: return '';
  }
}

function canonicalKind(kind) {
  switch (String(kind || '').toLowerCase()) {
    case 'navigation':
    case 'document':
    case 'main_frame':
    case 'main-frame':
    case 'sub_frame':
    case 'subframe': return 'document';
    case 'fetch':
    case 'xhr':
    case 'xmlhttprequest': return 'raw';
    case 'image': return 'image';
    case 'script': return 'script';
    case 'css':
    case 'stylesheet':
    case 'style-sheet': return 'style-sheet';
    case 'media':
    case 'hls':
    case 'm3u8': return 'media';
    case 'download': return 'download';
    default: return String(kind || '').toLowerCase();
  }
}

function hostMatch(filter, host, absolute) {
  if (filter.startsWith('||')) {
    const domain = filter.slice(2).split(/[\/^]/)[0].toLowerCase();
    if (!domain) return false;
    const hostOK = host === domain || host.endsWith('.' + domain);
    if (!hostOK) return false;
    const path = filter.slice(2 + domain.length).replace(/^\^/, '');
    if (path.startsWith('/')) return absolute.includes(path.toLowerCase());
    return true;
  }
  return absolute.includes(filter.toLowerCase());
}

function resourceVerdict(urlString, lines, kind) {
  const url = new URL(urlString);
  const host = url.hostname.toLowerCase();
  const absolute = url.toString().toLowerCase();
  const wanted = canonicalKind(kind);
  let blocked = false;
  for (const raw of lines) {
    const name = classify(raw);
    if (name !== 'block' && name !== 'allow') continue;
    const body = String(raw || '').trim().replace(/^@@/, '');
    const types = (modifierTokens(body) || []).map(typeName).filter(Boolean);
    if (wanted && types.length && !types.includes(wanted)) continue;
    if (!hostMatch(filterBody(raw), host, absolute)) continue;
    if (name === 'allow') return 'allow';
    blocked = true;
  }
  return blocked ? 'block' : 'none';
}

module.exports = { classify, options, redirectScriptlets, resourceVerdict };
