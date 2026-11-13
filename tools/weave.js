// Experiment: zone choices on a shared trunk (docs/research/shared-trunk.md, "weaving"). At one of the trunk's zone
// boundaries, take a runner-up zone for one leg instead, then rejoin the trunk where it was, minus what the side leg did:
//   - the side leg is planned by campaign.js from the trunk's own state at that boundary (work-0/before-<leg>.json),
//     forced to that zone for one leg
//   - the trunk from the boundary on drops every step of a quest the side leg handed in, and the pick-up of a quest it
//     picked up (its objectives and hand-in stay, wherever the trunk has them)
// The woven path goes through paths.js (--reuse: no replanning) so it gets the same safety net and walking paths as a
// built-in plan, then is wrapped as a Plan.lua to play with FR_SIM_PLAN (tools/simplay.js) and score with
// tools/score-plan.js against the trunk itself.
// usage: node tools/weave.js <trunk key, e.g. dwarf-hunter> <leg> <zone area id>
//        node tools/weave.js <trunk key> --list [minShare=0.8]   (the boundaries and runner-ups worth trying)
const fs = require('fs'), path = require('path');
const { execFileSync } = require('child_process');
const ROOT = path.join(__dirname, '..');
const [key, legArg, zArg] = process.argv.slice(2);
const src = path.join(ROOT, 'paths-starter', key);
const trunk = JSON.parse(fs.readFileSync(path.join(src, 'path-0.json'), 'utf8'));

if (legArg === '--list') {
  const share = +(zArg || 0.8);
  for (const c of trunk.choices) {
    if (c.leg < 3 || !c.options) continue;
    const ch = c.options.find((o) => o.z === c.chosen); if (!ch) continue;
    const alts = c.options.filter((o) => o.z !== c.chosen && o.xph >= share * ch.xph);
    if (alts.length) console.log(`leg ${c.leg} (level ${c.level}): ${ch.name} ${ch.xph} xp/h; ${alts.map((o) => `${o.name} [${o.z}] ${o.xph}`).join(', ')}`);
  }
  return;
}
const leg = +legArg, z = +zArg;
const c = trunk.choices.find((x) => x.leg === leg);
if (!c) throw new Error('no zone boundary at leg ' + leg);
const zName = (c.options.find((o) => o.z === z) || {}).name || String(z);
const out = path.join(ROOT, 'paths-starter', `weave-${key}-${leg}-${z}`);
fs.mkdirSync(out, { recursive: true });
// the trunk's plan files (rankings, zone routes, dungeons) so paths.js --reuse plans nothing again
for (const f of fs.readdirSync(src)) { const p = path.join(src, f); if (fs.statSync(p).isFile() && !/^Route\.lua$/.test(f)) fs.copyFileSync(p, path.join(out, f)); }
const base = JSON.parse(fs.readFileSync(path.join(src, 'campaign.json'), 'utf8'));

// 1. the side leg, from the trunk's state at the boundary
const altJson = path.join(out, 'side.json');
if (!fs.existsSync(altJson)) {
  const cfg = { ...base, startStateFile: c.beforeFile, firstZone: z, forceLegs: [z], maxLegs: 1, parallel: 2,
    workDir: path.join(out, 'work-side'), routeOut: path.join(out, 'side.lua'), pathOut: altJson };
  delete cfg.routesOut;
  const f = path.join(out, 'side-cfg.json'); fs.writeFileSync(f, JSON.stringify(cfg));
  const t0 = Date.now();
  execFileSync(process.execPath, ['--max-old-space-size=4000', path.join(__dirname, 'campaign.js'), f], { cwd: ROOT, stdio: ['ignore', fs.openSync(path.join(out, 'side.log'), 'w'), 'inherit'] });
  console.log(`side leg ${zName} planned in ${Math.round((Date.now() - t0) / 1000)} s`);
}
const side = JSON.parse(fs.readFileSync(altJson, 'utf8'));

// 2. weave: trunk up to the boundary, the side leg, the trunk from the boundary minus what the side leg did
const TRAVEL = new Set(['fly', 'boat', 'hearth', 'walk', 'go', 'portal', 'tram', 'ride']);
let cut = trunk.steps.findIndex((s) => s._choice === leg);
if (cut < 0) cut = c.at; else if (!TRAVEL.has(trunk.steps[cut].k)) cut++;
const handed = new Set(side.steps.filter((s) => s.k === 'turnin').map((s) => s.q));
const accepted = new Set(side.steps.filter((s) => s.k === 'accept').map((s) => s.q));
const off = trunk.sections.length;
const rest = trunk.steps.slice(cut).filter((s) => !(s.q && handed.has(s.q)) && !(s.k === 'accept' && accepted.has(s.q)));
const sideSteps = side.steps.map((s) => ({ ...s, sec: s.sec + off, _choice: undefined }));
const steps = trunk.steps.slice(0, cut).concat(sideSteps, rest).map((s, i) => ({ ...s, id: i + 1 }));
const woven = { ...trunk, legs: trunk.legs.slice(0, leg - 1).concat([zName], trunk.legs.slice(leg - 1)), sections: trunk.sections.concat(side.sections), steps,
  choices: trunk.choices.filter((x) => x.leg < leg), minutes: trunk.minutes };
fs.writeFileSync(path.join(out, 'path-0.json'), JSON.stringify(woven));
const droppedSteps = trunk.steps.length - cut - rest.length;
console.log(`woven at leg ${leg} (level ${c.level}, step ${cut}): ${zName} for ${side.steps.length} steps (${handed.size} hand-ins), trunk after it ${rest.length} of ${trunk.steps.length - cut} steps (${droppedSteps} done already)`);

// 3. through paths.js (no replanning) and wrapped as a Plan.lua
const cfg2 = { ...base, routesOut: path.join(out, 'Route.lua'), reuseDungeons: path.join(out, 'dungeons.json') };
fs.writeFileSync(path.join(out, 'campaign.json'), JSON.stringify(cfg2, null, 2));
execFileSync(process.execPath, ['--max-old-space-size=8000', path.join(__dirname, 'paths.js'), path.join(out, 'campaign.json'), '1', '0', '--work', out, '--reuse'], { cwd: ROOT, stdio: ['ignore', fs.openSync(path.join(out, 'paths.log'), 'w'), 'inherit'] });
const planFile = path.join(ROOT, 'addon', 'ForeverRoute_Starter_' + key.replace(/-/g, '_'), 'Plan.lua');
const head = fs.readFileSync(planFile, 'utf8').split(/\r?\n/);
const fnAt = head.findIndex((l) => /^ForeverRouteStarter\[/.test(l));
const plan = head.slice(0, fnAt + 1).concat(fs.readFileSync(path.join(out, 'Route.lua'), 'utf8').split(/\r?\n/), ['end', '']).join('\n');
fs.writeFileSync(path.join(out, 'Plan.lua'), plan);
console.log('-> ' + path.relative(ROOT, path.join(out, 'Plan.lua')));
