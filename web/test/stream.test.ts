import { describe, expect, it } from "vitest";
import { FrameSplitter, frameHeader } from "../src/stream.js";

/** An MPEG-1 Layer III header: 128 kb/s, 44.1 kHz, stereo, no padding (417-byte frames). */
const MP3_HEADER = [0xff, 0xfb, 0x90, 0x00];

function mp3Frame(fill: number): Uint8Array {
  const frame = new Uint8Array(417).fill(fill);
  frame.set(MP3_HEADER, 0);
  return frame;
}

/** An ADTS AAC-LC header: 44.1 kHz, stereo, `length` bytes. */
function adtsFrame(length: number): Uint8Array {
  const f = new Uint8Array(length);
  f.set([0xff, 0xf1, 0x50, 0x80 | ((length >> 11) & 3), (length >> 3) & 0xff, ((length & 7) << 5) | 0x1f, 0xfc]);
  return f;
}

function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

describe("frameHeader", () => {
  it("reads an MP3 header", () => {
    expect(frameHeader(mp3Frame(0), 0)).toEqual({ codec: "mp3", sampleRate: 44100, channels: 2, samples: 1152, length: 417 });
  });
  it("reads an ADTS header", () => {
    expect(frameHeader(adtsFrame(300), 0)).toEqual({
      codec: "mp4a.40.2",
      sampleRate: 44100,
      channels: 2,
      samples: 1024,
      length: 300,
    });
  });
  it("rejects bytes that are not a header", () => {
    expect(frameHeader(new Uint8Array([0x49, 0x44, 0x33, 4, 0, 0, 0, 0]), 0)).toBeNull();
    expect(frameHeader(new Uint8Array([0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0]), 0)).toBeNull();
  });
});

describe("FrameSplitter", () => {
  it("skips leading junk and splits frames across chunk boundaries", () => {
    const bytes = concat(new Uint8Array([1, 2, 0xff, 3, 4]), mp3Frame(7), mp3Frame(8), mp3Frame(9));
    const splitter = new FrameSplitter();
    const frames = [];
    for (let i = 0; i < bytes.length; i += 100) {
      splitter.push(bytes.subarray(i, i + 100));
      for (let f = splitter.next(); f; f = splitter.next()) frames.push(f);
    }
    // The last frame waits for the next header to confirm the lock only before the lock; after it, it is whole.
    expect(frames.map((f) => f.data[10])).toEqual([7, 8, 9]);
    expect(frames.every((f) => f.data.length === 417 && f.codec === "mp3")).toBe(true);
    expect(splitter.failed).toBe(false);
  });
  it("splits ADTS", () => {
    const splitter = new FrameSplitter();
    splitter.push(concat(adtsFrame(200), adtsFrame(210), adtsFrame(220)));
    const lengths = [];
    for (let f = splitter.next(); f; f = splitter.next()) lengths.push(f.data.length);
    expect(lengths).toEqual([200, 210, 220]);
  });
  it("gives up on bytes that never lock", () => {
    const splitter = new FrameSplitter();
    splitter.push(new Uint8Array(70_000).fill(0x41));
    expect(splitter.next()).toBeNull();
    expect(splitter.failed).toBe(true);
  });
});
