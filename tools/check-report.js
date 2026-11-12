// /fr report's format, both halves: a report packed by the addon (UI/Report.lua, in the simulator) must decode here
// (tools/report.js) to the same values, and the decoded save must load in the replay tools. tools/install.sh runs it.
// The vector below was packed by Report.Pack from the table in the "report vector" test of tests/all_test.lua; the
// test checks the addon still packs exactly this.
const assert = require('assert');
const path = require('path');
const fs = require('fs');
const os = require('os');
const { decode, toSave } = require('./report');
const VECTOR = 'FR1.AakBBTEuMi4yBTE2MDAxmLDT1wYFR25vbWUHV0FSTE9DSwhBbGxpYW5jZR65YMC4ApALuie8KApTb3V0aHNob3JlFmJ1aWx0LWluIGdub21lLXdhcmxvY2sQcGxhbnMgMjAyNi0xMS0xMBpwYXRoOkVsd3lubkZvcmVzdC1XZXN0ZmFsbAf_EhdvYmogV29yZ2VuIGluIHRoZSBXb29kc90BCW9iajoyMjEjMQIMAt0BAAEDDwDMCAEAAwcEBxrjBpwYBCkCFVNvdXRoc2hvcmUsIEhpbGxzYnJhZBFTdG9ybXdpbmQsIEVsd3lubgUUAQ9mbHk6OkR1c2t3b29kIzEAASIIBQEFDQEiBiMBsKjT1wYGaW5zZXJ0HpALEmFkZGVkIGZwIGFzIHN0ZXAgNwsTAQNuYXYCBGJvb20FNyBvYmoAAAkBDQ';
const d = decode('FR report 1.2.2 | test\n' + VECTOR);
const m = d.meta;
assert.strictEqual(m.version, '1.2.2'); assert.strictEqual(m.level, 30); assert.strictEqual(m.map, 1424);
assert.ok(Math.abs(m.x - 0.505) < 1e-4 && Math.abs(m.y - 0.518) < 1e-4);
assert.strictEqual(m.plan, 'built-in gnome-warlock'); assert.strictEqual(m.current, 7); assert.strictEqual(m.stepKey, 'obj:221#1');
assert.deepStrictEqual(d.log['221'].objectives[0], [3, 15, false]); assert.strictEqual(d.log['1100'].complete, true);
assert.deepStrictEqual(d.completed, [7, 33, 900, 4000]);
assert.deepStrictEqual(d.taxi, ['Southshore, Hillsbrad', 'Stormwind, Elwynn']);
assert.deepStrictEqual(d.ticks, { skipped: ['fly::Duskwood#1'], manualDone: [], nope: [34] });
assert.strictEqual(d.card[0].reason, 'behind you (joined mid-plan)'); assert.strictEqual(d.card[0].k, 'accept');
assert.strictEqual(d.why[0].x, 'added fp as step 7'); assert.strictEqual(d.errors[0].msg, 'boom'); assert.strictEqual(d.errors[0].version, '');
assert.deepStrictEqual(d.settings, { pathLine: true, pins: false, hideDone: true, markTarget: true });
// the decoded report loads as a character save
const f = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'fr-rep-')), 'ForeverRoute.lua');
fs.writeFileSync(f, toSave(d));
const c = require('./save-fixture').readChar(f);
assert.strictEqual(c.snapshot.level, 30); assert.strictEqual(c.snapshot.pos.map, 1424); assert.ok(c.manualDone !== undefined && c.knownTaxi['Stormwind, Elwynn']);
assert.ok(c.snapshot.log[221].objectives[0][0] === 3);
console.log('report format: addon and tools/report.js agree');
module.exports = { VECTOR };
