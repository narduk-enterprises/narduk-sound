import { SoundAnalyzer } from './analysis.js';
import { audioContextClass, type SampleSource } from './audio.js';

/**
 * Plays an http(s) MP3 or AAC (ADTS) stream by fetching it and decoding it with WebCodecs, never through a media
 * element. WebKit (Safari on every Apple device, and every iOS browser) hands `createMediaElementSource` silence for a
 * live, chunked stream such as an Icecast station even when the server sends CORS headers: the sound plays but the
 * analyser reads zeros. Here the bytes are split into frames, decoded by an `AudioDecoder` and scheduled back to back
 * as `AudioBufferSourceNode`s through the same `AnalyserNode` the visualizer reads, so the picture follows the sound
 * in every browser that has `AudioDecoder`.
 *
 * Construct it and call `start` inside a user gesture (the AudioContext resumes there). A live stream (no
 * Content-Length) is dropped on `pause` and fetched afresh on `resume`, so it comes back at the live edge; a file is
 * held by suspending the context. `start` rejects with `UnsupportedStreamError` when the bytes are neither MP3 nor
 * ADTS AAC, so a caller can fall back to a media element.
 */
export class StreamSource implements SampleSource {
  readonly element = null;
  readonly context: AudioContext;
  readonly analyser: AnalyserNode;
  /** The latest `SoundAnalyzer.windowSize` samples, oldest first. */
  readonly samples = new Float32Array(SoundAnalyzer.windowSize);
  private abort: AbortController | null = null;
  private decoder: AudioDecoder | null = null;
  private readonly playing = new Set<AudioBufferSourceNode>();
  private nextTime = 0;
  private paused = true;
  private live = true;
  private closed = false;

  /** True where this path can work: WebCodecs audio decoding, fetch streams and Web Audio. */
  static isSupported(): boolean {
    return (
      typeof AudioDecoder === 'function' &&
      typeof EncodedAudioChunk === 'function' &&
      typeof ReadableStream === 'function' &&
      audioContextClass() !== undefined
    );
  }

  private readonly ownsContext: boolean;
  private readonly output: AudioNode;

  /**
   * `options.context` shares a page's AudioContext (it is then never closed or suspended here); `options.muted`
   * analyses without playing, for a page whose own `<audio>` element is what the listener hears (the element keeps
   * iOS lock-screen playback; this feed only drives the picture).
   */
  constructor(
    readonly url: string,
    options: AudioContext | { context?: AudioContext; muted?: boolean } = {}
  ) {
    const shared = typeof BaseAudioContext === 'function' && options instanceof BaseAudioContext;
    const { context, muted = false } = shared
      ? { context: options as AudioContext }
      : (options as { context?: AudioContext; muted?: boolean });
    const Context = audioContextClass();
    if (!context && !Context) throw new Error('Web Audio is not available in this browser');
    this.ownsContext = !context;
    this.context = context ?? new Context!({ latencyHint: 'playback' });
    this.analyser = this.context.createAnalyser();
    this.analyser.fftSize = SoundAnalyzer.windowSize;
    this.analyser.smoothingTimeConstant = 0;
    // Muted, the analyser still feeds the destination (through a silent gain) so the graph keeps pulling samples.
    const gain = this.context.createGain();
    gain.gain.value = muted ? 0 : 1;
    this.analyser.connect(gain);
    gain.connect(this.context.destination);
    this.output = gain;
  }

  get sampleRate(): number {
    return this.context.sampleRate;
  }

  get isPaused(): boolean {
    return this.paused;
  }

  /** Resumes the context (inside the gesture) and plays; resolves when the first audio is scheduled. */
  async start(): Promise<void> {
    const session = (navigator as unknown as { audioSession?: { type: string } }).audioSession;
    if (session) {
      try {
        session.type = 'playback';
      } catch {
        /* not settable here; harmless */
      }
    }
    const resumed = this.context.state === 'running' ? Promise.resolve() : this.context.resume();
    if (!this.paused) return resumed;
    this.paused = false;
    // A held file continues where the suspended context stopped; a live stream (or a first start) fetches.
    if (this.decoder && !this.live && this.ownsContext) return resumed;
    await Promise.all([resumed, this.pump()]);
  }

  async pause(): Promise<void> {
    if (this.paused) return;
    this.paused = true;
    if (this.live) this.stopFetch();
    if (this.ownsContext) await this.context.suspend();
    else if (!this.live) this.stopFetch(); // a shared context keeps running, so a held file restarts on resume
  }

  async resume(): Promise<void> {
    await this.start();
  }

  read(): Float32Array {
    this.analyser.getFloatTimeDomainData(this.samples);
    return this.samples;
  }

  async close(): Promise<void> {
    this.closed = true;
    this.paused = true;
    this.stopFetch();
    this.analyser.disconnect();
    this.output.disconnect();
    if (this.ownsContext && this.context.state !== 'closed') await this.context.close();
  }

  private stopFetch(): void {
    this.abort?.abort();
    this.abort = null;
    if (this.decoder && this.decoder.state !== 'closed') this.decoder.close();
    this.decoder = null;
    for (const node of this.playing) {
      node.onended = null;
      try {
        node.stop();
      } catch {
        /* never started */
      }
      node.disconnect();
    }
    this.playing.clear();
    this.nextTime = 0;
  }

  /**
   * Fetches and decodes until the stream ends, it is paused or closed. Resolves once the first audio is scheduled
   * (or the stream ends with none); rejects if nothing could be played.
   */
  private pump(): Promise<void> {
    this.stopFetch();
    const abort = new AbortController();
    this.abort = abort;
    return new Promise<void>((resolve, reject) => {
      let settled = false;
      const ready = () => {
        if (!settled) {
          settled = true;
          resolve();
        }
      };
      const fail = (error: unknown) => {
        if (!settled) {
          settled = true;
          reject(error);
        }
      };
      this.run(abort, ready).then(
        () => fail(new Error('The stream ended before any audio arrived')),
        (error: unknown) => {
          if (abort.signal.aborted && settled) return;
          fail(abort.signal.aborted ? new Error('Stopped') : error);
        }
      );
    });
  }

  private async run(abort: AbortController, ready: () => void): Promise<void> {
    const response = await fetch(this.url, {
      signal: abort.signal,
      mode: 'cors',
      cache: 'no-store',
    });
    if (!response.ok || !response.body) throw new Error(`The stream answered ${response.status}`);
    this.live = !response.headers.get('content-length');
    const reader = response.body.getReader();
    const framer = new FrameSplitter();
    let timestamp = 0;
    let decodeError: unknown = null;
    while (!abort.signal.aborted) {
      const { value, done } = await reader.read();
      if (done) break;
      framer.push(value);
      for (let frame = framer.next(); frame; frame = framer.next()) {
        if (!this.decoder) {
          if (!AudioDecoder.isConfigSupported)
            throw new UnsupportedStreamError('This browser cannot decode audio');
          const config: AudioDecoderConfig = {
            codec: frame.codec,
            sampleRate: frame.sampleRate,
            numberOfChannels: frame.channels,
          };
          const support = await AudioDecoder.isConfigSupported(config);
          if (!support.supported)
            throw new UnsupportedStreamError(`This browser cannot decode ${frame.codec}`);
          if (abort.signal.aborted) return;
          this.decoder = new AudioDecoder({
            output: (data) => {
              if (this.abort === abort && this.schedule(data)) ready();
              else data.close();
            },
            error: (error) => {
              decodeError = error;
            },
          });
          this.decoder.configure(config);
        }
        if (decodeError) throw decodeError;
        this.decoder.decode(new EncodedAudioChunk({ type: 'key', timestamp, data: frame.data }));
        timestamp += (frame.samples / frame.sampleRate) * 1e6;
      }
      if (framer.failed)
        throw new UnsupportedStreamError('The stream is neither MP3 nor AAC (ADTS)');
    }
    if (this.decoder && this.decoder.state === 'configured') await this.decoder.flush();
    reader.cancel().catch(() => {});
  }

  /** Plays one decoded block right after the last one; returns whether it was scheduled. */
  private schedule(data: AudioData): boolean {
    if (this.closed || this.context.state === 'closed') {
      data.close();
      return false;
    }
    const frames = data.numberOfFrames;
    const channels = data.numberOfChannels;
    const buffer = this.context.createBuffer(channels, frames, data.sampleRate);
    copyPlanes(data, buffer);
    data.close();
    const node = this.context.createBufferSource();
    node.buffer = buffer;
    node.connect(this.analyser);
    const now = this.context.currentTime;
    // Start (or recover from an underrun) a little ahead, so the first blocks never cut in mid-sample.
    if (this.nextTime < now + 0.02) this.nextTime = now + 0.25;
    node.start(this.nextTime);
    this.nextTime += buffer.duration;
    this.playing.add(node);
    node.onended = () => {
      this.playing.delete(node);
      node.disconnect();
    };
    return true;
  }
}

/** The bytes were not a stream this path decodes: fall back to a media element. */
export class UnsupportedStreamError extends Error {
  override name = 'UnsupportedStreamError';
}

/** Copies `data` into `buffer`, one plane a channel, from whatever sample format the decoder chose. */
function copyPlanes(data: AudioData, buffer: AudioBuffer): void {
  const frames = data.numberOfFrames;
  const channels = data.numberOfChannels;
  const format = data.format ?? 'f32-planar';
  if (format === 'f32-planar') {
    for (let c = 0; c < channels; c++) data.copyTo(buffer.getChannelData(c), { planeIndex: c });
    return;
  }
  const planar = format.endsWith('-planar');
  const interleaved = planar ? 1 : channels;
  const scale = format.startsWith('s16')
    ? 1 / 32768
    : format.startsWith('s32')
      ? 1 / 2147483648
      : 1;
  for (let c = 0; c < (planar ? channels : 1); c++) {
    const size = data.allocationSize({ planeIndex: c });
    const raw = new ArrayBuffer(size);
    data.copyTo(raw, { planeIndex: c });
    const view: ArrayLike<number> = format.startsWith('f32')
      ? new Float32Array(raw)
      : format.startsWith('s16')
        ? new Int16Array(raw)
        : format.startsWith('s32')
          ? new Int32Array(raw)
          : Uint8Array.from(new Uint8Array(raw), (v) => v - 128);
    const u8 = format.startsWith('u8') ? 1 / 128 : scale;
    for (let ch = 0; ch < interleaved; ch++) {
      const out = buffer.getChannelData(planar ? c : ch);
      for (let i = 0; i < frames; i++) out[i] = view[i * interleaved + ch] * u8;
    }
  }
}

export interface AudioFrame {
  codec: string;
  sampleRate: number;
  channels: number;
  /** Samples per channel in the frame. */
  samples: number;
  data: Uint8Array;
}

const MPEG1_L3_KBPS = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320];
const MPEG2_L3_KBPS = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160];
const MPEG1_RATES = [44100, 48000, 32000];
const ADTS_RATES = [
  96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350,
];

/** Reads one MP3 (MPEG audio Layer III) or ADTS AAC frame header at `i`; null when there is none. */
export function frameHeader(
  b: Uint8Array,
  i: number
): (Omit<AudioFrame, 'data'> & { length: number }) | null {
  if (i + 7 > b.length || b[i] !== 0xff || (b[i + 1] & 0xe0) !== 0xe0) return null;
  const layer = (b[i + 1] >> 1) & 3;
  if (layer === 0) {
    // ADTS: 12 sync bits, then MPEG version, layer 00 and protection_absent.
    if ((b[i + 1] & 0xf0) !== 0xf0) return null;
    const profile = (b[i + 2] >> 6) & 3;
    const rate = ADTS_RATES[(b[i + 2] >> 2) & 15];
    const channels = ((b[i + 2] & 1) << 2) | (b[i + 3] >> 6);
    const length = ((b[i + 3] & 3) << 11) | (b[i + 4] << 3) | (b[i + 5] >> 5);
    if (!rate || channels === 0 || length < 7) return null;
    return { codec: `mp4a.40.${profile + 1}`, sampleRate: rate, channels, samples: 1024, length };
  }
  if (layer !== 1) return null; // Layer III only
  const version = (b[i + 1] >> 3) & 3; // 3 = MPEG-1, 2 = MPEG-2, 0 = MPEG-2.5
  if (version === 1) return null;
  const bitrateIndex = b[i + 2] >> 4;
  const rateIndex = (b[i + 2] >> 2) & 3;
  if (bitrateIndex === 0 || bitrateIndex === 15 || rateIndex === 3) return null;
  const mpeg1 = version === 3;
  const kbps = (mpeg1 ? MPEG1_L3_KBPS : MPEG2_L3_KBPS)[bitrateIndex];
  const sampleRate = MPEG1_RATES[rateIndex] / (mpeg1 ? 1 : version === 2 ? 2 : 4);
  const padding = (b[i + 2] >> 1) & 1;
  const length = Math.floor(((mpeg1 ? 144000 : 72000) * kbps) / sampleRate) + padding;
  const channels = b[i + 3] >> 6 === 3 ? 1 : 2;
  return { codec: 'mp3', sampleRate, channels, samples: mpeg1 ? 1152 : 576, length };
}

/**
 * Splits a byte stream into whole MP3 or ADTS frames. It locks on when two headers in a row agree (so a stray 0xFF in
 * an ID3 tag or a partial first frame is skipped), and gives up (`failed`) after 64 KB without a lock.
 */
export class FrameSplitter {
  private buffer = new Uint8Array(0);
  private locked = false;
  private scanned = 0;
  failed = false;

  push(chunk: Uint8Array): void {
    const merged = new Uint8Array(this.buffer.length + chunk.length);
    merged.set(this.buffer, 0);
    merged.set(chunk, this.buffer.length);
    this.buffer = merged;
  }

  next(): AudioFrame | null {
    const b = this.buffer;
    let i = 0;
    while (i + 7 <= b.length) {
      const h = frameHeader(b, i);
      if (h) {
        if (i + h.length > b.length) break; // wait for the rest of the frame
        // Before the lock, the next header must follow and agree.
        if (!this.locked) {
          if (i + h.length + 7 > b.length) break;
          const n = frameHeader(b, i + h.length);
          if (!n || n.codec !== h.codec || n.sampleRate !== h.sampleRate) {
            i++;
            continue;
          }
          this.locked = true;
        }
        const data = b.slice(i, i + h.length);
        this.buffer = b.subarray(i + h.length);
        this.scanned = 0;
        return {
          codec: h.codec,
          sampleRate: h.sampleRate,
          channels: h.channels,
          samples: h.samples,
          data,
        };
      }
      this.locked = false;
      i++;
    }
    this.scanned += i;
    if (this.scanned > 65536) this.failed = true;
    this.buffer = b.subarray(i);
    return null;
  }
}
