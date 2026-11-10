// Reward values (tools/quality.js) with the game's gear verdicts: a reward the game says isn't better than what you
// wear is worth nothing to the plan (Robes of Antiquity for Ruuzel was called an "armor upgrade" by item level alone).
// usage: node tools/test-quality.js
const fs = require('fs');
const path = require('path');
const ROOT = path.join(__dirname, '..');
const db = JSON.parse(fs.readFileSync(path.join(ROOT, 'qdb', 'db.json'), 'utf8'));
const items = JSON.parse(fs.readFileSync(path.join(ROOT, 'qdb', 'json', 'items.json'), 'utf8'));
const { makeQuality } = require('./quality');
let fails = 0;
const check = (name, ok, info) => { console.log((ok ? 'ok   ' : 'FAIL ') + name + (ok ? '' : '  ' + JSON.stringify(info))); if (!ok) fails++; };
const robes = +Object.keys(items).find((k) => items[k][1] === 'Robes of Antiquity');
const base = { quests: db.quests, npcs: db.npcs, objects: db.objects, items, cls: 'warlock' };
const before = makeQuality(base)(db.quests[1009], 24);
check('Ruuzel without a verdict: the robe counts by item level', before.rewardValue > 0 && before.rewardItem === robes, before);
const worse = makeQuality({ ...base, verdicts: { [robes]: -11 } })(db.quests[1009], 24);
check('...the game says it is worse than your robe: no reward value', worse.rewardValue === 0 && !worse.rewardText, worse);
const better = makeQuality({ ...base, verdicts: { [robes]: 9 } })(db.quests[1009], 24);
check('...the game says it is better: valued, and said so', better.rewardValue > 0 && /upgrade for you/.test(better.rewardText), better);
console.log(fails ? fails + ' failed' : 'all passed');
process.exitCode = fails ? 1 : 0;
