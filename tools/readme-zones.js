// README animation data: how the campaign picks the next zone, from a plan's campaign log (paths-*/path-0.log): two
// decisions in a row - the candidate zones with their simulated XP per hour, turn-ins and hours - and the pick; plus
// where each zone sits on the world canvas (tools/readme-world.js layout).
// usage: node tools/readme-zones.js <path-0.log> <world.json from readme-world.js> <first leg no> <out.json>
const fs = require('fs');
const [logFile, worldFile, legArg, outFile] = process.argv.slice(2);
const log = fs.readFileSync(logFile, 'utf8');
const world = JSON.parse(fs.readFileSync(worldFile, 'utf8'));
const legs = [];
for (const block of log.split(/\n(?=leg \d+ at level)/)) {
  const h = /^leg (\d+) at level (\d+): evaluated (\d+) zones/.exec(block); if (!h) continue;
  const cands = [...block.matchAll(/^ {2}([A-Z][A-Za-z' ]+?)\s{2,}(\d+) xp\/h\s+\((\d+) turn-ins, ([\d.]+) min\)/gm)].map((m) => ({ zone: m[1].trim(), xph: +m[2], turnins: +m[3], hours: +(+m[4] / 60).toFixed(1) }));
  const pick = /^ {2}-> ([^:(]+?)(?: \(\+[^)]*\))?: (\d+) steps, level (\d+) -> (\d+)/m.exec(block);
  legs.push({ leg: +h[1], level: +h[2], evaluated: +h[3], cands, pick: pick ? { zone: pick[1].trim(), steps: +pick[2], from: +pick[3], to: +pick[4] } : null });
}
const center = (name) => { const z = world.zones.find((x) => x.name === name); return z ? { x: z.x + z.w / 2, y: z.y + z.h / 2 } : null; };
const k = legs.findIndex((l) => l.leg === +legArg);
if (k < 1) throw new Error('no leg ' + legArg);
const take = [legs[k], legs[k + 1]].map((l, i) => ({ ...l, from: (i === 0 ? legs[k - 1] : legs[k]).pick.zone, cands: l.cands.map((c) => ({ ...c, at: center(c.zone) })) }));
for (const d of take) { d.fromAt = center(d.from); d.pick.at = center(d.pick.zone); }
fs.writeFileSync(outFile, JSON.stringify({ decisions: take, world: { W: world.W, H: world.H } }, null, 1));
console.log(take.map((d) => `level ${d.level}: from ${d.from}, ${d.cands.length} shown of ${d.evaluated} -> ${d.pick.zone} (${d.pick.from} -> ${d.pick.to})`).join('\n'));
