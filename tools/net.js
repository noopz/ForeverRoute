// The ride network (tools/travel-net.json, from tools/crossings.js) minus the borders you can't really walk across.
// The walk-map scan finds a "crossing" wherever the two zones' walkable ground touches; a few of those are mountain
// ridges the game doesn't let you over (travel-facts.json NO_CROSS: pairs of map ids). Every reader of the network
// loads it through here, so a blocked border stays blocked in the planner, the addon data and the zone neighbours.
const fs = require('fs');
const path = require('path');
function blocked(facts) {
  const s = new Set();
  for (const [a, b] of (facts && facts.NO_CROSS) || []) { s.add(a + ':' + b); s.add(b + ':' + a); }
  return s;
}
function filter(net, facts) {
  const no = blocked(facts);
  if (!net || !no.size) return net;
  const drop = new Set(net.nodes.filter((n) => n.kind === 'cross' && n.m2 && no.has(n.m + ':' + n.m2)).map((n) => n.id));
  if (!drop.size) return net;
  return { ...net, nodes: net.nodes.filter((n) => !drop.has(n.id)), edges: net.edges.filter((e) => !drop.has(e.a) && !drop.has(e.b)) };
}
function load(facts) {
  const f = path.join(__dirname, 'travel-net.json');
  if (!fs.existsSync(f)) return null;
  if (!facts) facts = JSON.parse(fs.readFileSync(path.join(__dirname, 'travel-facts.json'), 'utf8'));
  return filter(JSON.parse(fs.readFileSync(f, 'utf8')), facts);
}
module.exports = { load, filter };
