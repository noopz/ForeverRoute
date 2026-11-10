// README animations drawn in a browser canvas: loads a scene page (tools/readme-scenes/<name>.html), hands it the data,
// then for each frame calls window.draw(i) and saves a screenshot; tools/gifenc.js makes the GIF.
// usage: node tools/readme-render.js <scene> <data.json> <out.gif> [delay cs=6] [last frame cs=400]
// Needs playwright-core and a Chromium (PLAYWRIGHT_CORE: the package folder if it isn't installed here; FR_CHROME: the
// browser to run, if not the one that playwright-core version expects).
const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFileSync } = require('child_process');
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'playwright-core');

const [scene, dataFile, outGif, delay = '6', last = '400'] = process.argv.slice(2);
(async () => {
  const data = JSON.parse(fs.readFileSync(dataFile, 'utf8'));
  // the scenes read our own zone images from disk (and sample their colours), so local files count as one origin
  const browser = await chromium.launch({ args: ['--allow-file-access-from-files', '--disable-web-security'], ...(process.env.FR_CHROME ? { executablePath: process.env.FR_CHROME } : {}) });
  const page = await browser.newPage({ viewport: { width: data.W, height: data.H }, deviceScaleFactor: 1 });
  page.on('console', (m) => { if (m.type() === 'error') console.log('page: ' + m.text()); });
  await page.goto('file:///' + path.resolve(__dirname, 'readme-scenes', scene + '.html').replace(/\\/g, '/'));
  const frames = await page.evaluate(async (d) => window.init(d), data);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fr-frames-'));
  const holds = [];
  for (let i = 0; i < frames; i++) {
    const hold = await page.evaluate((k) => window.draw(k), i);
    if (hold) holds.push(i + ':' + hold);
    await page.locator('canvas').screenshot({ path: path.join(dir, 'frame-' + String(i).padStart(3, '0') + '.png') });
    if (i % 50 === 0) process.stdout.write(`frame ${i}/${frames}\r`);
  }
  await browser.close();
  execFileSync(process.execPath, [path.join(__dirname, 'gifenc.js'), dir, path.resolve(outGif), delay, last, holds.join(',')], { stdio: 'inherit' });
  if (process.env.FR_KEEP_FRAMES) console.log('frames kept in ' + dir); else fs.rmSync(dir, { recursive: true, force: true });
  console.log(`${frames} frames -> ${outGif} (${(fs.statSync(outGif).size / 1024).toFixed(0)} KB)`);
})();
