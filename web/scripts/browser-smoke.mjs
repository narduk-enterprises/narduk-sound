// Browser smoke test: builds the demo, serves it, and drives it in headless Chromium with the synthetic source (no
// network, no audio device). Proves each ported visualizer draws through WebGL2 and the Canvas2D fallback, animates,
// holds still when paused, and shows a still picture under prefers-reduced-motion. Screenshots go to test-results/.
import { mkdirSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";
import { build, preview } from "vite";

const root = fileURLToPath(new URL("..", import.meta.url));
const outDir = `${root}test-results`;
mkdirSync(outDir, { recursive: true });

await build({ root: `${root}demo`, logLevel: "warn", build: { outDir: `${root}dist-demo`, emptyOutDir: true } });
const server = await preview({ root: `${root}demo`, build: { outDir: `${root}dist-demo` }, preview: { port: 0, host: "127.0.0.1" }, logLevel: "warn" });
const base = server.resolvedUrls.local[0];

// SwiftShader gives headless Chromium a software WebGL2.
const browser = await chromium.launch({ args: ["--enable-unsafe-swiftshader", "--use-angle=swiftshader", "--ignore-gpu-blocklist"] });
const failures = [];
const check = (ok, message) => {
  console.log(`${ok ? "ok  " : "FAIL"} ${message}`);
  if (!ok) failures.push(message);
};

/** Mean luma, its spread across the frame and the share of lit pixels, from a PNG screenshot of the canvas. */
async function stats(page, png) {
  return page.evaluate(async (b64) => {
    const img = new Image();
    img.src = `data:image/png;base64,${b64}`;
    await img.decode();
    const c = document.createElement("canvas");
    c.width = 96;
    c.height = 54;
    const ctx = c.getContext("2d", { willReadFrequently: true });
    ctx.drawImage(img, 0, 0, c.width, c.height);
    const d = ctx.getImageData(0, 0, c.width, c.height).data;
    let sum = 0, sq = 0, lit = 0;
    const n = d.length / 4;
    for (let i = 0; i < d.length; i += 4) {
      const y = (0.2126 * d[i] + 0.7152 * d[i + 1] + 0.0722 * d[i + 2]) / 255;
      sum += y;
      sq += y * y;
      if (y > 0.08) lit++;
    }
    const mean = sum / n;
    return { mean, spread: Math.sqrt(Math.max(sq / n - mean * mean, 0)), lit: lit / n };
  }, png.toString("base64"));
}

async function open(query, { reducedMotion = "no-preference" } = {}) {
  const context = await browser.newContext({ viewport: { width: 960, height: 720 }, reducedMotion, deviceScaleFactor: 1 });
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => m.type() === "error" && errors.push(m.text()));
  await page.goto(`${base}?synthetic&${query}`);
  await page.click(".nsw-start");
  return { page, context, errors };
}

/** Four seconds of a 120 BPM kick and a chord, 16-bit mono WAV. */
function beatWav() {
  const rate = 22050;
  const n = rate * 4;
  const out = Buffer.alloc(44 + n * 2);
  out.write("RIFF", 0);
  out.writeUInt32LE(36 + n * 2, 4);
  out.write("WAVEfmt ", 8);
  out.writeUInt32LE(16, 16);
  out.writeUInt16LE(1, 20);
  out.writeUInt16LE(1, 22);
  out.writeUInt32LE(rate, 24);
  out.writeUInt32LE(rate * 2, 28);
  out.writeUInt16LE(2, 32);
  out.writeUInt16LE(16, 34);
  out.write("data", 36);
  out.writeUInt32LE(n * 2, 40);
  for (let i = 0; i < n; i++) {
    const t = i / rate;
    const b = t % 0.5;
    const kick = Math.sin(2 * Math.PI * (40 + 80 * Math.exp(-b * 30)) * b) * Math.exp(-b * 18);
    const chord = [220, 261.6, 329.6].reduce((sum, f) => sum + Math.sin(2 * Math.PI * f * t), 0) / 3;
    out.writeInt16LE(Math.round(Math.max(-1, Math.min(1, 0.6 * kick + 0.25 * chord)) * 32767), 44 + i * 2);
  }
  return out;
}

const shot = (page) => page.locator(".nsw-stage canvas").screenshot();
const status = (page) => page.locator(".nsw-status").textContent();
const same = (a, b) => Buffer.compare(a, b) === 0;

try {
  for (const renderer of ["auto", "canvas2d"]) {
    for (const visual of ["spectrum", "scope", "halo"]) {
      const label = `${visual} (${renderer})`;
      const { page, context, errors } = await open(`visual=${visual}&renderer=${renderer}`);
      await page.waitForTimeout(1500);
      const kind = await page.evaluate(() => globalThis.soundDemo.viz.renderer.kind);
      check(kind === (renderer === "auto" ? "webgl2" : "canvas2d"), `${label}: draws with ${kind}`);
      check((await status(page))?.startsWith("Playing"), `${label}: status "${await status(page)}"`);
      const a = await shot(page);
      writeFileSync(`${outDir}/${visual}-${renderer}.png`, a);
      const s = await stats(page, a);
      const drew = s.mean > 0.02 && s.spread > 0.02 && s.lit > 0.01;
      check(drew, `${label}: draws a picture (mean ${s.mean.toFixed(3)}, spread ${s.spread.toFixed(3)}, lit ${s.lit.toFixed(3)})`);
      if (!drew) {
        console.log(`     diagnostics ${JSON.stringify(await page.evaluate(() => {
          const v = globalThis.soundDemo.viz;
          const c = v.canvas ?? document.querySelector(".nsw-stage canvas");
          return { status: v.status, decision: v.governor.decision, canvas: [c.width, c.height], rms: v.state?.rms, hidden: document.hidden };
        }))}`);
      }
      await page.waitForTimeout(250);
      check(!same(a, await shot(page)), `${label}: animates`);

      if (visual === "halo") {
        await page.click(".nsw-controls button");
        await page.waitForTimeout(300);
        const p1 = await shot(page);
        await page.waitForTimeout(600);
        check((await status(page)) === "Paused" && same(p1, await shot(page)), `${label}: pause holds the last frame`);
        await page.click(".nsw-controls button");
        await page.waitForTimeout(400);
        check((await status(page))?.startsWith("Playing"), `${label}: resumes`);
      }
      const decision = await page.evaluate(() => globalThis.soundDemo.viz.governor.decision);
      console.log(`     budget ${decision.fps} fps at ${decision.pixelRatio.toFixed(2)}x`);
      check(errors.length === 0, `${label}: no page errors ${errors.join("; ")}`);
      await context.close();
    }
  }

  // A local file through the file input: decoded by the element, read by Web Audio, drawn.
  {
    const { page, context, errors } = await open("visual=spectrum");
    await page.setInputFiles("#file", { name: "beat.wav", mimeType: "audio/wav", buffer: beatWav() });
    await page.waitForTimeout(2000);
    const text = await status(page);
    const src = await page.evaluate(() => globalThis.soundDemo.viz.source?.element?.src ?? "");
    check(src.startsWith("blob:") && text?.startsWith("Playing"), `file input: plays the file (status "${text}")`);
    const s = await stats(page, await shot(page));
    check(s.lit > 0.01, `file input: draws the file's sound (lit ${s.lit.toFixed(3)})`);
    check(errors.length === 0, `file input: no page errors ${errors.join("; ")}`);
    await context.close();
  }

  // prefers-reduced-motion: a still picture, never animated.
  const { page, context, errors } = await open("visual=halo", { reducedMotion: "reduce" });
  await page.waitForTimeout(2500);
  const text = await status(page);
  check(text?.includes("reduced motion"), `reduced motion: status "${text}"`);
  const s1 = await shot(page);
  writeFileSync(`${outDir}/halo-reduced-motion.png`, s1);
  await page.waitForTimeout(1000);
  const s2 = await shot(page);
  const st = await stats(page, s1);
  check(same(s1, s2), "reduced motion: the picture holds still");
  check(st.mean > 0.02 && st.lit > 0.01, `reduced motion: the still shows the sound (mean ${st.mean.toFixed(3)})`);
  check(errors.length === 0, `reduced motion: no page errors ${errors.join("; ")}`);
  await context.close();
} finally {
  await browser.close();
  await new Promise((resolve) => server.httpServer.close(resolve));
}

if (failures.length) {
  console.error(`${failures.length} browser check(s) failed`);
  process.exit(1);
}
console.log("Browser smoke test passed");
