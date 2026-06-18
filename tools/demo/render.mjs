import puppeteer from 'puppeteer-core';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dir = dirname(fileURLToPath(import.meta.url));
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const N = Number(process.env.N || 90);          // total frames
const W = 1280, H = 720;
const OUT = join(__dir, 'out');

const browser = await puppeteer.launch({
  executablePath: CHROME,
  headless: 'new',
  args: ['--hide-scrollbars', '--no-sandbox'],
});
const page = await browser.newPage();
await page.setViewport({ width: W, height: H, deviceScaleFactor: 2 });
await page.goto('file://' + join(__dir, 'demo.html'));
await page.evaluate(async () => { await document.fonts.ready; });
// settle fonts/layout
await new Promise(r => setTimeout(r, 250));

const clip = { x: 0, y: 0, width: W, height: H };
for (let f = 0; f < N; f++) {
  const p = N === 1 ? 0 : f / (N - 1);
  await page.evaluate((p) => window.setProgress(p), p);
  await page.screenshot({ path: join(OUT, `frame_${String(f).padStart(4, '0')}.png`), clip });
}
await browser.close();
console.log(`rendered ${N} frames to ${OUT}`);
