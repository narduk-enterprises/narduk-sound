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

/** The demo in timeline mode: no audio source and no tap to start (the start control is hidden). */
async function openTimeline(query, { reducedMotion = "no-preference" } = {}) {
  const context = await browser.newContext({ viewport: { width: 960, height: 720 }, reducedMotion, deviceScaleFactor: 1 });
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  page.on("console", (m) => m.type() === "error" && errors.push(m.text()));
  await page.goto(`${base}?${query}`);
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
  // Every registered port (VISUALIZERS), read from the player's picker so a new port is smoke-tested without an edit here.
  const ids = await (async () => {
    const { page, context } = await open("visual=spectrum&renderer=canvas2d");
    const found = await page.$$eval('select[aria-label="Visualizer"] option', (options) => options.map((o) => o.value));
    await context.close();
    return found;
  })();
  check(ids.length >= 9 && ids.includes("halo"), `the picker lists ${ids.length} visualizers: ${ids.join(", ")}`);

  for (const renderer of ["auto", "canvas2d"]) {
    for (const visual of ids) {
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
      // Software WebGL can be slow on the heavy looks: give it a few frames' worth of time before calling it still.
      let animated = false;
      for (let attempt = 0; attempt < 4 && !animated; attempt++) {
        await page.waitForTimeout(250 * (attempt + 1));
        animated = !same(a, await shot(page));
      }
      check(animated, `${label}: animates`);

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

  // An id with no port or drawing of its own still draws the sound on Canvas2D (it borrows the nearest drawing).
  {
    const { page, context, errors } = await open("visual=halo&renderer=canvas2d");
    await page.waitForTimeout(500);
    await page.evaluate(() => globalThis.soundDemo.viz.setVisual("someFutureLook"));
    await page.waitForTimeout(1000);
    const s = await stats(page, await shot(page));
    check(s.mean > 0.02 && s.lit > 0.01, `unknown id (canvas2d): draws a fallback picture (mean ${s.mean.toFixed(3)}, lit ${s.lit.toFixed(3)})`);
    check(errors.length === 0, `unknown id (canvas2d): no page errors ${errors.join("; ")}`);
    await context.close();
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

  // A recorded timeline and a playhead, no audio: draws, animates, runs the beat clock, pauses and resumes.
  {
    const { page, context, errors } = await openTimeline("timeline=fixture&visual=halo");
    await page.waitForFunction(() => globalThis.soundDemo.viz.driver === "timeline", null, { timeout: 15000 });
    await page.waitForTimeout(1500);
    const info = await page.evaluate(() => {
      const v = globalThis.soundDemo.viz;
      return { driver: v.driver, source: v.source, status: v.status, running: v.state.isRunning, beats: v.state.beats };
    });
    check(info.driver === "timeline" && info.source === null, "timeline: drawn from the timeline with no audio source");
    check(info.status === "playing" && info.running, `timeline: playing with the recorded beat clock (status ${info.status}, beats ${info.beats.toFixed(1)})`);
    const a = await shot(page);
    writeFileSync(`${outDir}/halo-timeline.png`, a);
    const st = await stats(page, a);
    check(st.mean > 0.02 && st.spread > 0.02 && st.lit > 0.01, `timeline: draws a picture (mean ${st.mean.toFixed(3)}, lit ${st.lit.toFixed(3)})`);
    let animated = false;
    for (let attempt = 0; attempt < 4 && !animated; attempt++) {
      await page.waitForTimeout(250 * (attempt + 1));
      animated = !same(a, await shot(page));
    }
    check(animated, "timeline: animates");
    check((await page.locator("#timeline-note").textContent())?.includes("web-fixture-1"), "timeline: the demo names the track");
    await page.click(".nsw-controls button");
    await page.waitForTimeout(300);
    const p1 = await shot(page);
    await page.waitForTimeout(600);
    check((await status(page)) === "Paused" && same(p1, await shot(page)), "timeline: pause holds the last frame");
    await page.click(".nsw-controls button");
    await page.waitForTimeout(400);
    check((await status(page))?.startsWith("Playing"), "timeline: resumes");
    // The playhead going away stops the beat clock at once and fades the picture to the ambient drift; it comes back.
    await page.evaluate(() => (globalThis.soundDemo.demo.hold = true));
    await page.waitForTimeout(600);
    check(await page.evaluate(() => !globalThis.soundDemo.viz.state.isRunning), "timeline: a null playhead stops the beat clock");
    await page.waitForTimeout(5500);
    const faded = await page.evaluate(() => ({ driver: globalThis.soundDemo.viz.driver, energy: globalThis.soundDemo.viz.state.energy }));
    check(faded.driver === "timeline" && faded.energy < 0.3, `timeline: a null playhead fades to the ambient drift (energy ${faded.energy.toFixed(3)})`);
    const quiet = await stats(page, await shot(page));
    check(quiet.mean > 0.003, `timeline: the ambient drift still draws (mean ${quiet.mean.toFixed(3)})`);
    await page.evaluate(() => (globalThis.soundDemo.demo.hold = false));
    await page.waitForTimeout(1500);
    check(await page.evaluate(() => globalThis.soundDemo.viz.state.isRunning), "timeline: plays again when the playhead returns");
    check(errors.length === 0, `timeline: no page errors ${errors.join("; ")}`);
    await context.close();
  }

  // The ambient drift alone: draws and breathes.
  {
    const { page, context, errors } = await openTimeline("ambient&visual=halo");
    await page.waitForFunction(() => globalThis.soundDemo.viz.driver === "ambient", null, { timeout: 15000 });
    await page.waitForTimeout(1200);
    const running = await page.evaluate(() => globalThis.soundDemo.viz.state.isRunning);
    const a = await shot(page);
    writeFileSync(`${outDir}/halo-ambient.png`, a);
    const st = await stats(page, a);
    check(!running && st.lit > 0.0 && st.mean > 0.003, `ambient: draws a quiet picture with no beat clock (mean ${st.mean.toFixed(3)}, lit ${st.lit.toFixed(3)})`);
    let animated = false;
    for (let attempt = 0; attempt < 4 && !animated; attempt++) {
      await page.waitForTimeout(250 * (attempt + 1));
      animated = !same(a, await shot(page));
    }
    check(animated, "ambient: breathes");
    check(errors.length === 0, `ambient: no page errors ${errors.join("; ")}`);
    await context.close();
  }

  // A timeline URL that is not a timeline: the error is shown and the ambient drift keeps drawing.
  {
    const { page, context, errors } = await openTimeline("timeline=/not-a-timeline&visual=halo");
    await page.waitForFunction(() => document.getElementById("timeline-note").textContent.startsWith("Could not load"), null, { timeout: 15000 });
    check((await page.evaluate(() => globalThis.soundDemo.viz.driver)) === "ambient", "bad timeline: falls back to the ambient drift");
    check(errors.length === 0, `bad timeline: no page errors ${errors.join("; ")}`);
    await context.close();
  }

  // Reduced motion with a timeline: one still of the playhead.
  {
    const { page, context, errors } = await openTimeline("timeline=fixture&visual=halo", { reducedMotion: "reduce" });
    await page.waitForFunction(() => globalThis.soundDemo.viz.driver === "timeline", null, { timeout: 15000 });
    await page.waitForTimeout(1500);
    const s1 = await shot(page);
    await page.waitForTimeout(1000);
    check((await status(page))?.includes("reduced motion") && same(s1, await shot(page)), "timeline, reduced motion: the picture holds still");
    check(errors.length === 0, `timeline, reduced motion: no page errors ${errors.join("; ")}`);
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
