'use strict';

const scriptlets = new Set(['abort-on-property-read', 'abort-on-property-write', 'json-prune', 'set-constant', 'prevent-fetch', 'prevent-xhr']);

function scriptletName(line) {
  const body = line.includes('#%#') ? line.split('#%#').slice(1).join('#%#') : (line.split('##+js(')[1] || '');
  const text = body.replace(/^\/\/scriptlet\(/, '').replace(/\)$/, '');
  const name = text.split(',')[0].replace(/['"\s]/g, '');
  return scriptlets.has(name) ? name : '';
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
  const dollar = line.lastIndexOf('$');
  if (dollar > 0) {
    const mods = line.slice(dollar + 1).split(',');
    if (mods.some(token => token === 'jsonprune')) return 'drop';
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

module.exports = { classify, options, redirectScriptlets };
