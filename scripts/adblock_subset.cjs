'use strict';

const destructive = new Set(['redirect', 'redirect-rule', 'removeparam', 'csp', 'replace', 'jsonprune']);

function classify(raw) {
  const line = String(raw || '').trim();
  if (!line || line.startsWith('!') || line.startsWith('[') || line.startsWith('#%#')) return 'drop';
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
    if (mods.some(token => destructive.has(token))) return 'drop';
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

module.exports = { classify, options };
