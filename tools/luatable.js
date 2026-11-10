// Parse WoW SavedVariables files (Lua assignments of table literals) into JS objects.
// parseSavedVariables(text) -> { GlobalName: value, ... }
function parseSavedVariables(src) {
  let i = 0;
  const n = src.length;
  const ws = () => {
    for (;;) {
      while (i < n && /\s/.test(src[i])) i++;
      if (src.startsWith('--', i)) { const m = /^--\[(=*)\[/.exec(src.slice(i, i + 16)); if (m) { const e = src.indexOf(']' + m[1] + ']', i); i = e + m[1].length + 2; } else { while (i < n && src[i] !== '\n') i++; } continue; }
      break;
    }
  };
  const str = () => {
    const q = src[i++];
    let out = '';
    while (i < n && src[i] !== q) {
      if (src[i] === '\\') {
        i++; const c = src[i];
        if (c === 'n') out += '\n'; else if (c === 't') out += '\t'; else if (c === 'r') out += '\r';
        else if (/\d/.test(c)) { let d = ''; while (d.length < 3 && /\d/.test(src[i])) d += src[i++]; out += String.fromCharCode(+d); continue; }
        else out += c;
        i++;
      } else out += src[i++];
    }
    i++;
    return out;
  };
  const value = () => {
    ws();
    const c = src[i];
    if (c === '{') return table();
    if (c === '"' || c === "'") return str();
    if (src.startsWith('[[', i)) { const e = src.indexOf(']]', i); const s = src.slice(i + 2, e); i = e + 2; return s; }
    const m = /^(-?(?:0x[0-9a-fA-F]+|\d+\.?\d*(?:[eE][-+]?\d+)?|\.\d+)|true|false|nil|-?inf|-?nan)/.exec(src.slice(i, i + 40));
    if (!m) throw new Error('unexpected at ' + i + ': ' + src.slice(i, i + 30));
    i += m[0].length;
    if (m[0] === 'true') return true; if (m[0] === 'false') return false; if (m[0] === 'nil') return null;
    return Number(m[0]);
  };
  const table = () => {
    i++; // {
    const arr = [], obj = {};
    let isArr = true, next = 1;
    for (;;) {
      ws();
      if (src[i] === '}') { i++; break; }
      let key;
      if (src[i] === '[') { i++; key = value(); ws(); i++; /* ] */ ws(); i++; /* = */ }
      else {
        const m = /^([A-Za-z_]\w*)\s*=(?!=)/.exec(src.slice(i, i + 80));
        if (m) { key = m[1]; i += m[0].length; }
      }
      const v = value();
      if (key === undefined) { key = next++; }
      if (typeof key === 'number' && key === arr.length + 1 && isArr) arr.push(v); else { isArr = false; obj[key] = v; }
      ws(); if (src[i] === ',' || src[i] === ';') i++;
    }
    if (isArr) return arr;
    arr.forEach((v, k) => { obj[k + 1] = v; });
    return obj;
  };
  const out = {};
  for (;;) {
    ws();
    if (i >= n) break;
    const m = /^([A-Za-z_]\w*)\s*=/.exec(src.slice(i, i + 80));
    if (!m) throw new Error('expected assignment at ' + i);
    i += m[0].length;
    out[m[1]] = value();
  }
  return out;
}
module.exports = { parseSavedVariables };

if (require.main === module) {
  const fs = require('fs');
  console.log(JSON.stringify(parseSavedVariables(fs.readFileSync(process.argv[2], 'utf8')), null, 1).slice(0, 3000));
}
