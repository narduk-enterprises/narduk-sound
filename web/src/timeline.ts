import { SoundFrameLayout, emptyFrame, type SoundFrame } from "./frame.js";
import { HIT_LANE_COUNT, emptyMusicContext, type MusicContext } from "./inference.js";
import type { SongSection } from "./palette.js";

const f = Math.fround;
// Float arithmetic: each operation rounds to 32 bits as Swift's `Float` does.
const add = (x: number, y: number) => f(x + y);
const sub = (x: number, y: number) => f(x - y);
const mul = (x: number, y: number) => f(x * y);

/**
 * `SoundTimeline.Header` (Sources/NardukSoundVisuals/Timeline/SoundTimeline.swift): the JSON header of a version-1
 * container. Field names are Swift's. `tempoBPM` and `inference` are optional in the file (Swift's encoder omits a nil
 * optional) and read as `null` here.
 */
export interface SoundTimelineHeader {
  formatVersion: number;
  /** Whatever names the track to the app that plays it (a file name, an Apple Music catalog id). */
  trackID: string;
  /** Seconds of audio analyzed. */
  duration: number;
  /** Samples per second; sample `k` is the state at `k / gridRate` seconds into the track. */
  gridRate: number;
  sampleCount: number;
  /** The tempo the beat clock held when the recording ended; null when it never locked. */
  tempoBPM: number | null;
  /** The `Instrument` index of each recorded hit lane, ascending: the lanes that ever fired. */
  hitLanes: number[];
  waveformPoints: number;
  /** The waveform is stored with sample 0, `waveformEvery`, 2 * `waveformEvery`, ... */
  waveformEvery: number;
  stepsPerBar: number;
  stepsPerPhrase: number;
  buildThreshold: number;
  dropThreshold: number;
  analysisSampleRate: number;
  analysisRate: number;
  /** The `SoundMusicInference` constants the timeline was inferred with; null when the context came from elsewhere. */
  inference: {
    gridRate: number;
    minBPM: number;
    maxBPM: number;
    defaultBPM: number;
    tempoInterval: number;
    agreementsToLock: number;
    agreementsToSwitch: number;
    silenceDB: number;
  } | null;
}

/**
 * A decoded NSTL v1 timeline: the header plus planar samples (`header.sampleCount` of each, times the stride in the
 * comment). Read-only data; replay it with `SoundTimelinePlayer`.
 */
export interface SoundTimeline {
  header: SoundTimelineHeader;
  /** x 64 bands, value / 255. */
  spectrum: Uint8Array;
  /** x 12 pitch classes, value / 255. */
  chroma: Uint8Array;
  rmsCentiDB: Int16Array;
  peakCentiDB: Int16Array;
  /** Bits 0 ... 2 the section code, bit 3 `isRunning`, bit 4 `dropQueued`. */
  flags: Uint8Array;
  /** wobbleCutoff, value / 255. */
  cutoff: Uint8Array;
  /** value / 255. */
  energy: Uint8Array;
  /** The beat clock in 16th steps with the fraction through the current one. */
  position: Float32Array;
  /** `secondsPerStep` in units of `STEP_UNIT` seconds. */
  stepDuration: Uint16Array;
  /** x `hitLanes.length`: hits since the previous sample on each recorded lane. */
  hits: Uint8Array;
  /** Companded (`sign * sqrt(|x|) * 127`) x `waveformPoints`, for every `waveformEvery`-th sample. */
  waveform: Int8Array;
}

export type SoundTimelineErrorReason = "notATimeline" | "unsupportedVersion" | "truncated" | "inconsistent";

/** `SoundTimeline.DecodingError`: thrown by `decodeSoundTimeline` for another format, a newer version or damaged data. */
export class SoundTimelineError extends Error {
  readonly reason: SoundTimelineErrorReason;
  /** The version the container declared, for `unsupportedVersion`. */
  readonly version?: number;
  constructor(reason: SoundTimelineErrorReason, detail?: string, version?: number) {
    super(detail ? `SoundTimeline: ${reason} (${detail})` : `SoundTimeline: ${reason}`);
    this.name = "SoundTimelineError";
    this.reason = reason;
    this.version = version;
  }
}

export const TIMELINE_FORMAT_VERSION = 1;
/** Seconds per unit of `stepDuration`. */
export const STEP_UNIT = 4e-6;
const BANDS = SoundFrameLayout.spectrumCount;
const CHROMA = SoundFrameLayout.chromaCount;
const MAGIC = [0x4e, 0x53, 0x54, 0x4c]; // "NSTL"

const waveformSamples = (count: number, every: number) => Math.floor((count + Math.max(every, 1) - 1) / Math.max(every, 1));

/** Bytes of the sample payload (`SoundTimeline.payloadByteCount`). */
function payloadByteCount(h: SoundTimelineHeader): number {
  const n = h.sampleCount;
  const perSample = BANDS + CHROMA + 2 + 2 + 1 + 1 + 1 + 4 + 2 + h.hitLanes.length;
  return n * perSample + waveformSamples(n, h.waveformEvery) * h.waveformPoints;
}

const isNumber = (x: unknown): x is number => typeof x === "number" && Number.isFinite(x);

function parseHeader(json: string): SoundTimelineHeader {
  let raw: unknown;
  try {
    raw = JSON.parse(json);
  } catch (error) {
    throw new SoundTimelineError("inconsistent", `header: ${error instanceof Error ? error.message : String(error)}`);
  }
  if (typeof raw !== "object" || raw === null) throw new SoundTimelineError("inconsistent", "header: not an object");
  const h = raw as Record<string, unknown>;
  const number = (key: string): number => {
    const v = h[key];
    if (!isNumber(v)) throw new SoundTimelineError("inconsistent", `header: ${key} is not a number`);
    return v;
  };
  if (typeof h.trackID !== "string") throw new SoundTimelineError("inconsistent", "header: trackID is not a string");
  if (!Array.isArray(h.hitLanes) || !h.hitLanes.every(isNumber)) {
    throw new SoundTimelineError("inconsistent", "header: hitLanes is not a list of numbers");
  }
  let inference: SoundTimelineHeader["inference"] = null;
  if (typeof h.inference === "object" && h.inference !== null) {
    const i = h.inference as Record<string, unknown>;
    const keys = [
      "gridRate",
      "minBPM",
      "maxBPM",
      "defaultBPM",
      "tempoInterval",
      "agreementsToLock",
      "agreementsToSwitch",
      "silenceDB",
    ] as const;
    if (!keys.every((k) => isNumber(i[k]))) throw new SoundTimelineError("inconsistent", "header: inference");
    inference = Object.fromEntries(keys.map((k) => [k, i[k] as number])) as NonNullable<SoundTimelineHeader["inference"]>;
  }
  return {
    formatVersion: number("formatVersion"),
    trackID: h.trackID,
    duration: number("duration"),
    gridRate: number("gridRate"),
    sampleCount: number("sampleCount"),
    tempoBPM: isNumber(h.tempoBPM) ? h.tempoBPM : null,
    hitLanes: h.hitLanes as number[],
    waveformPoints: number("waveformPoints"),
    waveformEvery: number("waveformEvery"),
    stepsPerBar: number("stepsPerBar"),
    stepsPerPhrase: number("stepsPerPhrase"),
    buildThreshold: number("buildThreshold"),
    dropThreshold: number("dropThreshold"),
    analysisSampleRate: number("analysisSampleRate"),
    analysisRate: number("analysisRate"),
    inference,
  };
}

/**
 * Reads an NSTL container (`SoundTimeline.init(decoding:)`): `NSTL`, a UInt16 version, a UInt32 header length, the
 * header as JSON, then planar little-endian blocks, one per stored field. Throws `SoundTimelineError` for another
 * format (`notATimeline`), a newer version (`unsupportedVersion`), a short file (`truncated`) or damaged data
 * (`inconsistent`, including trailing bytes).
 */
export function decodeSoundTimeline(bytes: ArrayBuffer | ArrayBufferView): SoundTimeline {
  const view =
    ArrayBuffer.isView(bytes)
      ? new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
      : new DataView(bytes);
  const total = view.byteLength;
  if (total < 10 || MAGIC.some((byte, i) => view.getUint8(i) !== byte)) throw new SoundTimelineError("notATimeline");
  const version = view.getUint16(4, true);
  if (version !== TIMELINE_FORMAT_VERSION) throw new SoundTimelineError("unsupportedVersion", undefined, version);
  const headerLength = view.getUint32(6, true);
  if (total < 10 + headerLength) throw new SoundTimelineError("truncated");
  const json = new TextDecoder("utf-8").decode(new Uint8Array(view.buffer, view.byteOffset + 10, headerLength));
  const header = parseHeader(json);
  if (header.formatVersion !== TIMELINE_FORMAT_VERSION) {
    throw new SoundTimelineError("unsupportedVersion", undefined, header.formatVersion);
  }
  const n = header.sampleCount;
  const lanes = header.hitLanes.length;
  if (
    !(Number.isInteger(n) && n >= 0) ||
    !(Number.isInteger(header.waveformPoints) && header.waveformPoints > 0) ||
    !(Number.isInteger(header.waveformEvery) && header.waveformEvery > 0) ||
    !(header.gridRate > 0) ||
    !header.hitLanes.every((lane) => Number.isInteger(lane) && lane >= 0 && lane < HIT_LANE_COUNT)
  ) {
    throw new SoundTimelineError("inconsistent", "header values out of range");
  }
  const expected = payloadByteCount(header);
  const available = total - 10 - headerLength;
  if (available < expected) throw new SoundTimelineError("truncated");
  if (available !== expected) throw new SoundTimelineError("inconsistent", "trailing bytes");

  let offset = 10 + headerLength;
  const take = <T extends Uint8Array | Int8Array>(Type: new (length: number) => T, count: number): T => {
    const out = new Type(count);
    out.set(new Uint8Array(view.buffer, view.byteOffset + offset, count) as unknown as ArrayLike<number>);
    offset += count;
    return out;
  };
  // Multi-byte blocks start at arbitrary offsets: read each value little-endian through the view.
  const takeInt16 = (count: number): Int16Array => {
    const out = new Int16Array(count);
    for (let i = 0; i < count; i++) out[i] = view.getInt16(offset + i * 2, true);
    offset += count * 2;
    return out;
  };
  const takeUint16 = (count: number): Uint16Array => {
    const out = new Uint16Array(count);
    for (let i = 0; i < count; i++) out[i] = view.getUint16(offset + i * 2, true);
    offset += count * 2;
    return out;
  };
  const takeFloat32 = (count: number): Float32Array => {
    const out = new Float32Array(count);
    for (let i = 0; i < count; i++) out[i] = view.getFloat32(offset + i * 4, true);
    offset += count * 4;
    return out;
  };
  return {
    header,
    spectrum: take(Uint8Array, n * BANDS),
    chroma: take(Uint8Array, n * CHROMA),
    rmsCentiDB: takeInt16(n),
    peakCentiDB: takeInt16(n),
    flags: take(Uint8Array, n),
    cutoff: take(Uint8Array, n),
    energy: take(Uint8Array, n),
    position: takeFloat32(n),
    stepDuration: takeUint16(n),
    hits: take(Uint8Array, n * lanes),
    waveform: take(Int8Array, waveformSamples(n, header.waveformEvery) * header.waveformPoints),
  };
}

/** `SoundTimeline.expand`: undoes the companding of a stored waveform point. */
function expand(code: number): number {
  const magnitude = f(Math.abs(code) / 127);
  const value = f(magnitude * magnitude);
  return code < 0 ? -value : value;
}

/** `SoundTimeline.section(code:)`. */
function sectionOf(code: number): SongSection {
  switch (code & 7) {
    case 1:
      return "build";
    case 2:
      return "drop";
    case 3:
      return "breakdown";
    case 4:
      return "drop2";
    default:
      return "intro";
  }
}

/** What the visualizers consume (`SoundVisualInput`): a frame and the music context that goes with it. */
export interface SoundVisualInput {
  frame: SoundFrame;
  music: MusicContext;
}

/**
 * Replays a `SoundTimeline` against the track's playback time (`SoundTimelinePlayer`): `input(time)` returns the frame
 * and `MusicContext` that `SoundVisualState.update(frame, now, options, music)` consumes, as a live analysis and
 * `SoundMusicInference` would have produced them.
 *
 * - The spectrum, chroma and levels are interpolated between the two samples around `time`; the waveform, section and
 *   flags come from the nearest sample. Every new `time` is a new frame (`sequence` counts up from 1); asking again for
 *   the same `time` returns the same input.
 * - The beat clock is the recorded position interpolated between samples.
 * - Hit counters are the player's own and only go up. Hits between two calls a short way apart (up to
 *   `continuityWindow` seconds) are added to them; a seek in either direction, or a longer gap, adds none, so the
 *   state sees no burst after a jump. A backward seek lowers `step`, which the state treats as a seek.
 * - At or past the end it holds the last sample with `isRunning` false.
 *
 * The returned object (and its arrays) is the player's own and is rewritten by the next `input` call: copy
 * `hitCounts` and the arrays to keep a snapshot (the state does). Not thread-safe: own one per drawing clock.
 */
export class SoundTimelinePlayer {
  /** Calls this far apart (seconds of track time) or closer count the hits between them. */
  static readonly continuityWindow = 0.5;

  readonly timeline: SoundTimeline;

  private readonly lanes: number[];
  /** Running hit totals per recorded lane, sample-major (`sample * lanes.length + lane`). */
  private readonly cumulative: Uint32Array;
  private readonly out: SoundVisualInput = { frame: emptyFrame(), music: emptyMusicContext() };
  private readonly counters = new Uint32Array(HIT_LANE_COUNT);
  private lastSample: number | null = null;
  private lastTime = -Infinity;
  private sequence = 0;
  private cachedTime = NaN;
  private ended = false;
  private waveformSample = -1;

  constructor(timeline: SoundTimeline) {
    this.timeline = timeline;
    const lanes = timeline.header.hitLanes;
    this.lanes = lanes;
    const n = timeline.header.sampleCount;
    const running = new Uint32Array(n * lanes.length);
    const totals = new Uint32Array(lanes.length);
    for (let k = 0; k < n; k++) {
      for (let l = 0; l < lanes.length; l++) {
        totals[l] += timeline.hits[k * lanes.length + l];
        running[k * lanes.length + l] = totals[l];
      }
    }
    this.cumulative = running;
  }

  get duration(): number {
    return this.timeline.header.duration;
  }

  /** Forgets where the playback was (a new track, a new state): the next call adopts the counters without hits. */
  reset(): void {
    this.counters.fill(0);
    this.lastSample = null;
    this.lastTime = -Infinity;
    this.sequence = 0;
    this.cachedTime = NaN;
    this.ended = false;
    this.waveformSample = -1;
  }

  /** What the visualizers see `time` seconds into the track. */
  input(time: number): SoundVisualInput {
    const timeline = this.timeline;
    const header = timeline.header;
    const n = header.sampleCount;
    if (n <= 0) return this.out;
    time = Number.isFinite(time) ? Math.max(time, 0) : 0;
    if (this.cachedTime === time) return this.out;
    const rate = header.gridRate;
    const ended = time >= header.duration;
    // Past the end the picture holds: the same input (and sequence) however long the caller keeps asking.
    if (ended && this.ended) return this.out;
    const position = ended ? n - 1 : Math.min(time * rate + 1e-9, n - 1);
    const i = Math.min(Math.floor(position), n - 1);
    const j = Math.min(i + 1, n - 1);
    const fraction = ended ? 0 : f(position - i);
    const near = fraction >= 0.5 ? j : i;

    // Hit counters: add the hits passed on a continuous forward step; nothing on a seek.
    const previous = this.lastSample;
    if (previous !== null && time >= this.lastTime && time - this.lastTime <= SoundTimelinePlayer.continuityWindow) {
      if (near > previous) this.addHits(previous, near);
    }
    this.lastSample = near;
    this.lastTime = time;

    this.fillFrame(time, i, j, fraction, near);
    this.fillContext(i, j, ended ? 0 : fraction, near, ended);
    this.cachedTime = time;
    this.ended = ended;
    return this.out;
  }

  private addHits(from: number, to: number): void {
    const lanes = this.lanes.length;
    for (let l = 0; l < lanes; l++) {
      this.counters[this.lanes[l]] += this.cumulative[to * lanes + l] - this.cumulative[from * lanes + l];
    }
  }

  private fillFrame(time: number, i: number, j: number, fraction: number, near: number): void {
    const t = this.timeline;
    const frame = this.out.frame;
    const inverse = f(1 / 255);
    for (let b = 0; b < BANDS; b++) {
      const a = t.spectrum[i * BANDS + b];
      const c = t.spectrum[j * BANDS + b];
      frame.spectrum[b] = f(f(a + f(f(c - a) * fraction)) * inverse);
    }
    for (let p = 0; p < CHROMA; p++) {
      const a = t.chroma[i * CHROMA + p];
      const c = t.chroma[j * CHROMA + p];
      frame.chroma[p] = f(f(a + f(f(c - a) * fraction)) * inverse);
    }
    const rms = f(t.rmsCentiDB[i] + f(f(t.rmsCentiDB[j] - t.rmsCentiDB[i]) * fraction));
    const peak = f(t.peakCentiDB[i] + f(f(t.peakCentiDB[j] - t.peakCentiDB[i]) * fraction));
    const stored = Math.floor(near / t.header.waveformEvery);
    if (this.waveformSample !== stored) {
      this.restoreWaveform(stored);
      this.waveformSample = stored;
    }
    this.sequence += 1;
    frame.sequence = this.sequence;
    frame.time = time;
    frame.peakDB = f(peak / 100);
    frame.rmsDB = f(rms / 100);
  }

  /**
   * The stored points are box means of 16 samples; a Catmull-Rom curve through them gives the 512 the shaders index
   * (and the scope's trigger scans).
   */
  private restoreWaveform(sample: number): void {
    const points = this.timeline.header.waveformPoints;
    const base = sample * points;
    const count = SoundFrameLayout.waveformCount;
    const span = f(count / points);
    const wave = this.timeline.waveform;
    const point = (k: number) => expand(wave[base + Math.min(Math.max(k, 0), points - 1)]);
    const out = this.out.frame.waveform;
    for (let x = 0; x < count; x++) {
      const u = f(f(f(x + 0.5) / span) - 0.5);
      const k = Math.floor(u);
      const t = f(u - k);
      const p0 = point(k - 1);
      const p1 = point(k);
      const p2 = point(k + 1);
      const p3 = point(k + 2);
      // Swift's expression, rounded to Float at each operation and associated left to right.
      const a = 2 * p1;
      const b = mul(add(-p0, p2), t);
      const c = mul(mul(sub(add(sub(2 * p0, mul(5, p1)), 4 * p2), p3), t), t);
      const d = mul(mul(mul(add(sub(add(-p0, mul(3, p1)), mul(3, p2)), p3), t), t), t);
      const value = mul(0.5, add(add(add(a, b), c), d));
      out[x] = Math.min(Math.max(value, -1), 1);
    }
  }

  private fillContext(i: number, j: number, fraction: number, near: number, ended: boolean): void {
    const t = this.timeline;
    const header = t.header;
    const first = t.position[i];
    const second = t.position[j];
    // Between two samples the clock runs from one position to the next; across a reset it holds.
    const clock = j !== i && second >= first && second - first <= 8 ? first + (second - first) * fraction : first;
    const step = Math.floor(clock);
    const flags = t.flags[near];
    const sectionPhase = clock / 4 - Math.floor(clock / 4);
    const phrase = Math.max(header.stepsPerPhrase, 1);
    const music = this.out.music;
    music.hitCounts = this.counters;
    music.step = step;
    music.section = sectionOf(flags);
    music.energy = f(t.energy[near] / 255);
    music.wobblePhase = f((sectionPhase * 2) % 1);
    music.wobbleCutoff = f(t.cutoff[near] / 255);
    music.isRunning = !ended && (flags & 8) !== 0;
    music.secondsPerStep = t.stepDuration[near] * STEP_UNIT;
    music.stepsPerBar = header.stepsPerBar;
    music.stepsPerPhrase = header.stepsPerPhrase;
    music.phraseProgress = f(f((((step % phrase) + phrase) % phrase)) / f(phrase));
    music.buildThreshold = f(header.buildThreshold);
    music.dropThreshold = f(header.dropThreshold);
    music.dropQueued = (flags & 16) !== 0;
  }
}
