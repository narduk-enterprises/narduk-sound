// How visibly the looks react to music: builds the demo, plays the live stream (or `--synthetic`) in headless Chromium
// and logs, per drawn frame, the envelopes the shaders read (u.env kick/snare/hat/impact, energy, wild), the spectrum
// spread and the onset detectors' flux against their thresholds, then prints a summary. Each channel is logged twice
// from one run: `state` is what `SoundVisualState` computes (the Swift-pinned drive, the "before") and `drawn` is what
// reached the shader uniforms after the web `LiveDrive` layer (the "after"), so both see the same audio. `--no-live`
// turns the layer off, to measure its effect on the photosensitivity watchdog.
//
//   node scripts/measure-reactivity.mjs [--synthetic] [--seconds=20] [--visual=halo] [--src=URL] [--out=file.json]
//                                       [--shots=dir] [--no-live]
//
// It reads private fields of the visualizer (`music`, `frame`) at runtime: this is a diagnostic, not an API.
import { mkdirSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";
import { build, preview } from "vite";

const args = Object.fromEntries(
  process.argv.slice(2).map((a) => {
    const [k, v] = a.replace(/^--/, "").split("=");
    return [k, v ?? true];
  }),
);
const seconds = Number(args.seconds ?? 20);
const warmup = Number(args.warmup ?? 4);
const visual = args.visual ?? "halo";
const synthetic = Boolean(args.synthetic);

const root = fileURLToPath(new URL("..", import.meta.url));
const outDir = `${root}test-results`;
mkdirSync(outDir, { recursive: true });

await build({ root: `${root}demo`, logLevel: "warn", build: { outDir: `${root}dist-demo`, emptyOutDir: true } });
const server = await preview({ root: `${root}demo`, build: { outDir: `${root}dist-demo` }, preview: { port: 0, host: "127.0.0.1" }, logLevel: "warn" });
const base = server.resolvedUrls.local[0];

const browser = await chromium.launch({
  args: ["--enable-unsafe-swiftshader", "--use-angle=swiftshader", "--ignore-gpu-blocklist", "--autoplay-policy=no-user-gesture-required"],
});
const context = await browser.newContext({ viewport: { width: 960, height: 540 }, deviceScaleFactor: 1 });
const page = await context.newPage();
const errors = [];
page.on("pageerror", (e) => errors.push(String(e)));
page.on("console", (m) => m.type() === "error" && errors.push(m.text()));

const query = new URLSearchParams({ visual });
if (synthetic) query.set("synthetic", "");
if (args.src) query.set("src", args.src);
await page.goto(`${base}?${query}`);
await page.click(".nsw-start");
await page.waitForFunction(() => globalThis.soundDemo?.viz.status === "playing", null, { timeout: 30000 });
if (args["no-live"]) await page.evaluate(() => { globalThis.soundDemo.viz.live.enabled = false; });
await page.waitForTimeout(warmup * 1000);

// Log every animation frame for `seconds`.
await page.evaluate((seconds) => {
  const viz = globalThis.soundDemo.viz;
  const log = (globalThis.__log = { rows: [], done: false, ctx: null });
  const source = viz.source;
  if (source?.context) log.ctx = { base: source.context.baseLatency, output: source.context.outputLatency ?? null, rate: source.context.sampleRate };
  const t0 = performance.now();
  const sample = () => {
    const now = performance.now();
    const s = viz.state;
    const m = viz.music;
    const f = viz.frame;
    let lo = 1, hi = 0, sum = 0;
    for (let i = 0; i < f.spectrum.length; i++) {
      const v = f.spectrum[i];
      lo = Math.min(lo, v);
      hi = Math.max(hi, v);
      sum += v;
    }
    const lane = (l) => ({ flux: l.lastFlux, threshold: l.floor + l.mean + l.sigma * l.deviation });
    const k = lane(m.kick), sn = lane(m.snare), h = lane(m.hat);
    const u = viz.inputs.uniforms;
    const d = viz.inputs.data;
    let dlo = 1, dhi = 0, dsum = 0;
    for (let i = 0; i < 64; i++) {
      dlo = Math.min(dlo, d[i]);
      dhi = Math.max(dhi, d[i]);
      dsum += d[i];
    }
    log.rows.push([
      now - t0, s.kick, s.snare, s.hat, s.impact, s.energy, s.wild, s.dropAmount, lo, hi, sum / f.spectrum.length,
      f.rmsDB, f.peakDB, m.latest.hitCounts[0], m.latest.hitCounts[1], m.latest.hitCounts[2], m.isLocked ? 1 : 0, m.tempoBPM ?? 0,
      k.flux, k.threshold, sn.flux, sn.threshold, h.flux, h.threshold, m.loudness, m.level, s.travel,
      u[4], u[5], u[6], u[7], u[10], u[16], dsum / 64, dlo, dhi, viz.watchdog.gain, viz.watchdog.isDimming ? 1 : 0, viz.live.deviation.reduce((a, b) => a + b, 0) / 64,
    ]);
    if (now - t0 < seconds * 1000) requestAnimationFrame(sample);
    else log.done = true;
  };
  requestAnimationFrame(sample);
}, seconds);

// Screenshots of a look reacting: a quiet moment and just after a kick (envelope high).
if (args.shots) {
  mkdirSync(args.shots, { recursive: true });
  let calm = false;
  let hit = false;
  const canvas = page.locator("canvas").first();
  const deadline = Date.now() + seconds * 1000;
  while (Date.now() < deadline && !(calm && hit)) {
    const kick = await page.evaluate(() => globalThis.soundDemo.viz.state.kick);
    if (!hit && kick > 0.9) {
      await canvas.screenshot({ path: `${args.shots}/${synthetic ? "synthetic" : "live"}-${visual}-kick.png` });
      hit = true;
    } else if (!calm && kick < 0.03 && hit) {
      await canvas.screenshot({ path: `${args.shots}/${synthetic ? "synthetic" : "live"}-${visual}-rest.png` });
      calm = true;
    }
    await page.waitForTimeout(25);
  }
}
await page.waitForFunction(() => globalThis.__log.done, null, { timeout: (seconds + 30) * 1000 });
const { rows, ctx } = await page.evaluate(() => globalThis.__log);
await browser.close();
server.httpServer.close();

const COLS = [
  "t", "kick", "snare", "hat", "impact", "energy", "wild", "drop", "specMin", "specMax", "specMean", "rmsDB", "peakDB",
  "kickHits", "snareHits", "hatHits", "locked", "bpm", "kFlux", "kThr", "sFlux", "sThr", "hFlux", "hThr", "loudness", "level", "travel",
  "dKick", "dSnare", "dHat", "dImpact", "dEnergy", "dWild", "dSpecMean", "dSpecMin", "dSpecMax", "wdGain", "wdDim", "bandDev",
];
const col = (name) => rows.map((r) => r[COLS.indexOf(name)]);
const mean = (a) => a.reduce((x, y) => x + y, 0) / Math.max(a.length, 1);
const std = (a) => {
  const m = mean(a);
  return Math.sqrt(mean(a.map((x) => (x - m) ** 2)));
};
const pct = (a, p) => {
  const s = [...a].sort((x, y) => x - y);
  return s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))];
};
const r3 = (x) => Math.round(x * 1000) / 1000;
const span = (rows.at(-1)[0] - rows[0][0]) / 1000;

/** Onsets per minute from a monotonic hit counter. */
const perMin = (c) => ((c.at(-1) - c[0]) / span) * 60;
const T = col("t");
/** Mean seconds for an envelope to fall to 10 % of each local peak above 0.3 (before it is struck again). */
function decay(env) {
  const times = [];
  for (let i = 1; i < env.length - 1; i++) {
    if (env[i] > 0.3 && env[i] >= env[i - 1] && env[i] > env[i + 1]) {
      for (let j = i + 1; j < env.length; j++) {
        if (env[j] > env[j - 1] + 0.02) break; // struck again
        if (env[j] <= env[i] * 0.1) {
          times.push((T[j] - T[i]) / 1000);
          break;
        }
      }
    }
  }
  return times.length ? r3(mean(times)) : null;
}
/** Share of the time an envelope is lit (above 0.25): how much of the song a hit is visibly on screen. */
const lit = (a) => r3(a.filter((x) => x > 0.25).length / a.length);
/** The p10 ... p90 swing and the spread of one channel: the headline "how much does it move". */
const motion = (a) => ({ mean: r3(mean(a)), p10: r3(pct(a, 10)), p90: r3(pct(a, 90)), swing: r3(pct(a, 90) - pct(a, 10)), std: r3(std(a)) });
/** Mean frame-to-frame change: how fast the channel moves. */
const speed = (a) => r3(mean(a.slice(1).map((x, i) => Math.abs(x - a[i]))));
/** Share of frames whose onset flux reaches `frac` of its detector's threshold (near misses). */
const near = (flux, thr, frac) => r3(flux.filter((x, i) => x > thr[i] * frac).length / flux.length);
const channel = (state, drawn) => ({
  before: { ...motion(col(state)), lit: lit(col(state)), decayTo10pct: decay(col(state)), perFrame: speed(col(state)) },
  after: { ...motion(col(drawn)), lit: lit(col(drawn)), decayTo10pct: decay(col(drawn)), perFrame: speed(col(drawn)) },
});

const stateBandSpread = col("specMax").map((hi, i) => hi - col("specMin")[i]);
const drawnBandSpread = col("dSpecMax").map((hi, i) => hi - col("dSpecMin")[i]);
const summary = {
  mode: synthetic ? "synthetic" : args.src ?? "live KZFR",
  visual,
  layer: args["no-live"] ? "off" : "on",
  seconds: r3(span),
  fps: r3(rows.length / span),
  audioContext: ctx,
  rmsDB: { mean: r3(mean(col("rmsDB"))), p5: r3(pct(col("rmsDB"), 5)), p95: r3(pct(col("rmsDB"), 95)) },
  crestDB: r3(mean(col("peakDB")) - mean(col("rmsDB"))),
  onsetsPerMin: { kick: r3(perMin(col("kickHits"))), snare: r3(perMin(col("snareHits"))), hat: r3(perMin(col("hatHits"))) },
  // Each channel: before = the state's value (the shipped drive), after = what the shader was given.
  energy: channel("energy", "dEnergy"),
  wild: channel("wild", "dWild"),
  kick: channel("kick", "dKick"),
  snare: channel("snare", "dSnare"),
  hat: channel("hat", "dHat"),
  spectrumMeanLevel: { before: motion(col("specMean")), after: motion(col("dSpecMean")) },
  spectrumBandSpread: { before: r3(mean(stateBandSpread)), after: r3(mean(drawnBandSpread)) },
  tempo: { lockedShare: r3(mean(col("locked"))), bpm: r3(col("bpm").at(-1)), bpmStd: r3(std(col("bpm").filter((b) => b > 0))) },
  nearMiss80: { kick: near(col("kFlux"), col("kThr"), 0.8), snare: near(col("sFlux"), col("sThr"), 0.8), hat: near(col("hFlux"), col("hThr"), 0.8) },
  bandDeviation: motion(col("bandDev")),
  watchdog: { dimmingShare: r3(mean(col("wdDim"))), minGain: r3(Math.min(...col("wdGain"))) },
  errors,
};
console.log(JSON.stringify(summary, null, 2));
if (args.out) writeFileSync(args.out === true ? `${outDir}/reactivity.json` : args.out, JSON.stringify({ summary, cols: COLS, rows }));
