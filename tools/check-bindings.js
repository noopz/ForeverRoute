// Bindings.xml against the names Core.lua gives them: every binding in it needs a BINDING_NAME (or the keybindings
// window shows a blank row), and the Target key must be there (the options hint pointed at one that didn't exist).
// The UI simulator doesn't load addon bindings, so tools/install.sh runs this instead.
// usage: node tools/check-bindings.js [addon dir]
const fs = require('fs');
const path = require('path');
const dir = process.argv[2] || path.join(__dirname, '..', 'addon', 'ForeverRoute');
const xml = fs.readFileSync(path.join(dir, 'Bindings.xml'), 'utf8');
const lua = fs.readdirSync(dir).filter((f) => f.endsWith('.lua')).map((f) => fs.readFileSync(path.join(dir, f), 'utf8')).join('\n');
const names = [...xml.matchAll(/<Binding\s+name="([^"]+)"/g)].map((m) => m[1]);
const bad = [];
for (const n of names) {
  // BINDING_NAME_FOREVERROUTE_SKIP = "..."  or  _G["BINDING_NAME_CLICK ForeverRouteTargetButton:LeftButton"] = "..."
  if (!lua.includes('BINDING_NAME_' + n + ' =') && !lua.includes('"BINDING_NAME_' + n + '"')) bad.push(n + ': no BINDING_NAME');
}
if (!names.includes('CLICK ForeverRouteTargetButton:LeftButton')) bad.push('the Target key (CLICK ForeverRouteTargetButton:LeftButton) is missing');
if (bad.length) { console.log('Bindings.xml: ' + bad.join('; ')); process.exit(1); }
console.log(`bindings: ${names.length}, all named`);
