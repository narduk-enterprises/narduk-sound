import type { RGB } from "./palette.js";
import type { SoundRenderer } from "./renderer.js";
import type { VisualizerId } from "./shaders/index.js";
import type { SoundVisualState } from "./state.js";
import { Aux, DATA_WIDTH, DataRow, type ShaderInputs } from "./uniforms.js";

/**
 * The Canvas2D fallback, for browsers without WebGL2 (or with it blocklisted): a lighter drawing of each look from the
 * same state, palette and safety rules. Strokes and fills only (no `shadowBlur`, no filters), so it holds the frame
 * budget on the slow devices that land here. The luma watchdog's gain is a black veil drawn over the frame.
 */
export class Canvas2DRenderer implements SoundRenderer {
  readonly kind = "canvas2d" as const;
  private readonly ctx: CanvasRenderingContext2D;
  private readonly probe: CanvasRenderingContext2D | null;
  private visual: VisualizerId = "spectrum";
  private frame = 0;
  private luma: number | null = null;

  constructor(private readonly canvas: HTMLCanvasElement) {
    const ctx = canvas.getContext("2d", { alpha: false });
    if (!ctx) throw new Error("Canvas2D is not available");
    this.ctx = ctx;
    const probe = document.createElement("canvas");
    probe.width = 8;
    probe.height = 8;
    this.probe = probe.getContext("2d", { willReadFrequently: true });
  }

  setVisual(id: VisualizerId): void {
    this.visual = id;
  }

  resize(width: number, height: number): void {
    this.canvas.width = Math.max(1, Math.floor(width));
    this.canvas.height = Math.max(1, Math.floor(height));
  }

  draw(inputs: ShaderInputs, state: SoundVisualState, gain: number): void {
    const { ctx, canvas } = this;
    const w = canvas.width;
    const h = canvas.height;
    const u = inputs.uniforms;
    const c0: RGB = [u[20], u[21], u[22]];
    const c1: RGB = [u[24], u[25], u[26]];
    const c2: RGB = [u[28], u[29], u[30]];
    ctx.globalAlpha = 1;
    ctx.globalCompositeOperation = "source-over";
    ctx.fillStyle = "rgb(2, 4, 10)";
    ctx.fillRect(0, 0, w, h);
    ctx.globalCompositeOperation = "lighter";
    if (this.visual === "spectrum") drawSpectrum(ctx, w, h, inputs, state, c0, c1, c2);
    else if (this.visual === "scope") drawScope(ctx, w, h, inputs, c0, c1, c2);
    else drawHalo(ctx, w, h, inputs, state, c0, c1, c2);
    ctx.globalCompositeOperation = "source-over";
    // The rationed flash, then the watchdog's dim.
    const flash = inputs.drive.flash * 0.2;
    if (flash > 0) {
      ctx.fillStyle = css(inputs.drive.flashColor, flash);
      ctx.fillRect(0, 0, w, h);
    }
    if (gain < 0.999) {
      ctx.fillStyle = `rgba(0, 0, 0, ${1 - gain})`;
      ctx.fillRect(0, 0, w, h);
    }
    this.frame += 1;
    if (this.probe && this.frame % 2 === 0) {
      this.probe.drawImage(canvas, 0, 0, 8, 8);
      const px = this.probe.getImageData(0, 0, 8, 8).data;
      let sum = 0;
      for (let i = 0; i < px.length; i += 4) sum += px[i] + px[i + 1] + px[i + 2];
      this.luma = sum / (64 * 3 * 255);
    }
  }

  takeLuma(): number | null {
    const luma = this.luma;
    this.luma = null;
    return luma;
  }

  destroy(): void {}
}

function css(c: RGB, alpha = 1): string {
  const b = (v: number) => Math.round(Math.min(Math.max(v, 0), 1) * 255);
  return `rgba(${b(c[0])}, ${b(c[1])}, ${b(c[2])}, ${alpha})`;
}

function paletteAt(c0: RGB, c1: RGB, c2: RGB, t: number): RGB {
  const f = (t - Math.floor(t)) * 3;
  let s = f - Math.floor(f);
  s = s * s * (3 - 2 * s);
  const [a, b] = f < 1 ? [c0, c1] : f < 2 ? [c1, c2] : [c2, c0];
  return [a[0] + (b[0] - a[0]) * s, a[1] + (b[1] - a[1]) * s, a[2] + (b[2] - a[2]) * s];
}

function drawSpectrum(
  ctx: CanvasRenderingContext2D,
  w: number,
  h: number,
  inputs: ShaderInputs,
  state: SoundVisualState,
  c0: RGB,
  c1: RGB,
  c2: RGB,
): void {
  const data = inputs.data;
  const base = h * 0.76;
  const usable = h * 0.56;
  const slot = (w * 0.92) / 64;
  const x0 = w * 0.04;
  const kick = state.kick;
  for (let i = 0; i < 64; i++) {
    const v = Math.min(Math.pow(data[DataRow.spectrum * DATA_WIDTH + i], 0.7), 1);
    const peak = Math.min(Math.pow(data[DataRow.aux * DATA_WIDTH + Aux.peaks + i], 0.7), 1);
    const hue = paletteAt(c0, c1, c2, (i / 63) * 0.66);
    const x = x0 + i * slot + slot * 0.18;
    const bw = slot * 0.64;
    const top = base - Math.max(2, usable * v);
    const grad = ctx.createLinearGradient(0, base, 0, top);
    grad.addColorStop(0, css(hue, 0.35 + 0.3 * kick));
    grad.addColorStop(1, css([0.4 + hue[0] * 0.6, 0.4 + hue[1] * 0.6, 0.4 + hue[2] * 0.6], 0.95));
    ctx.fillStyle = grad;
    ctx.fillRect(x, top, bw, base - top);
    // The reflection on the floor.
    ctx.fillStyle = css(hue, 0.12);
    ctx.fillRect(x, base + 2, bw, (base - top) * 0.35);
    // The peak-hold bead.
    ctx.fillStyle = css([0.6 + hue[0] * 0.4, 0.6 + hue[1] * 0.4, 0.6 + hue[2] * 0.4], 0.8);
    ctx.fillRect(x, base - usable * peak - h * 0.022, bw, Math.max(1, h * 0.005));
  }
  ctx.fillStyle = css(c1, 0.35 + 0.4 * kick);
  ctx.fillRect(w * 0.03, base, w * 0.94, Math.max(1, h * 0.004));
}

function drawScope(ctx: CanvasRenderingContext2D, w: number, h: number, inputs: ShaderInputs, c0: RGB, c1: RGB, c2: RGB): void {
  const data = inputs.data;
  const aux = DataRow.aux * DATA_WIDTH;
  const trigger = data[aux + Aux.scopeTrigger];
  const silent = data[aux + Aux.silent] > 0.5;
  const time = inputs.uniforms[2];
  const x0 = w * 0.04;
  const span = w * 0.92;
  // The graticule.
  ctx.strokeStyle = css([(c0[0] + c1[0]) / 2, (c0[1] + c1[1]) / 2, (c0[2] + c1[2]) / 2], 0.12);
  ctx.lineWidth = 1;
  ctx.beginPath();
  for (let i = 0; i <= 8; i++) {
    ctx.moveTo(x0 + (span * i) / 8, h * 0.07);
    ctx.lineTo(x0 + (span * i) / 8, h * 0.93);
  }
  for (let j = 0; j <= 4; j++) {
    ctx.moveTo(x0, h * (0.1 + 0.2 * j));
    ctx.lineTo(x0 + span, h * (0.1 + 0.2 * j));
  }
  ctx.stroke();
  // Older traces, receding up the glass.
  for (let age = 5; age >= 1; age--) {
    const base = DataRow.history * DATA_WIDTH + age * Aux.historyPoints;
    const scaleX = 1 - 0.09 * age;
    const centerY = h * (0.5 - 0.075 * age);
    const height = h * 0.4 * (1 - 0.13 * age);
    const depth = age / 5;
    ctx.strokeStyle = css(
      [c1[0] + (c0[0] - c1[0]) * depth, c1[1] + (c0[1] - c1[1]) * depth, c1[2] + (c0[2] - c1[2]) * depth],
      0.5 * Math.pow(0.66, age),
    );
    ctx.lineWidth = Math.max(1, h * 0.004);
    ctx.beginPath();
    for (let k = 0; k < Aux.historyPoints; k++) {
      const x = x0 + span * (0.5 + (k / 127 - 0.5) * scaleX);
      const y = centerY - data[base + k] * height;
      if (k === 0) ctx.moveTo(x, y);
      else ctx.lineTo(x, y);
    }
    ctx.stroke();
  }
  // The beam: a wide soft stroke under a thin hot one.
  const wave = DataRow.waveform * DATA_WIDTH;
  const path = new Path2D();
  for (let k = 0; k <= 191; k++) {
    const s = trigger + k * 2;
    const amp = silent ? 0.06 * Math.sin(time * 2.5 + s * 0.07) : data[wave + Math.min(511, Math.round(s))];
    const x = x0 + (span * k) / 191;
    const y = h * (0.5 - amp * 0.4);
    if (k === 0) path.moveTo(x, y);
    else path.lineTo(x, y);
  }
  ctx.strokeStyle = css(c1, 0.25);
  ctx.lineWidth = Math.max(3, h * 0.02);
  ctx.stroke(path);
  ctx.strokeStyle = css([0.45 + c1[0] * 0.55, 0.45 + c1[1] * 0.55, 0.45 + c1[2] * 0.55], 0.95);
  ctx.lineWidth = Math.max(1.5, h * 0.005);
  ctx.stroke(path);
  void c2;
}

function drawHalo(
  ctx: CanvasRenderingContext2D,
  w: number,
  h: number,
  inputs: ShaderInputs,
  state: SoundVisualState,
  c0: RGB,
  c1: RGB,
  c2: RGB,
): void {
  const data = inputs.data;
  const cx = w / 2;
  const cy = h / 2;
  const unit = h / 2;
  const beats = inputs.uniforms[3];
  const kick = state.kick;
  const coreR = 0.3 * unit * (1 + 0.12 * kick);
  const inner = coreR + 0.04 * unit;
  const maxLength = 0.46 * unit;
  const rotation = (beats / 16) * Math.PI * 2 - Math.PI / 2;
  // Needles on both sides of the turning axis, bass nearest it.
  ctx.lineCap = "round";
  ctx.lineWidth = Math.max(1.5, unit * 0.012);
  for (let side = -1; side <= 1; side += 2) {
    for (let i = 0; i < 64; i++) {
      const v = Math.pow(data[DataRow.spectrum * DATA_WIDTH + i], 0.8);
      const angle = rotation + side * ((i + 0.5) / 64) * Math.PI;
      const len = Math.max(0.012 * unit, v * maxLength);
      const cos = Math.cos(angle);
      const sin = Math.sin(angle);
      ctx.strokeStyle = css(paletteAt(c0, c1, c2, ((i + 0.5) / 64) * 0.66), 0.45 + 0.55 * v);
      ctx.beginPath();
      ctx.moveTo(cx + cos * inner, cy - sin * inner);
      ctx.lineTo(cx + cos * (inner + len), cy - sin * (inner + len));
      ctx.stroke();
    }
  }
  // The core and the waveform ring inside it.
  const grad = ctx.createRadialGradient(cx - coreR * 0.3, cy - coreR * 0.3, coreR * 0.1, cx, cy, coreR);
  grad.addColorStop(0, css([0.5 + c1[0] * 0.5, 0.5 + c1[1] * 0.5, 0.5 + c1[2] * 0.5], 0.5));
  grad.addColorStop(0.7, css(c0, 0.35));
  grad.addColorStop(1, css(c2, 0.55));
  ctx.fillStyle = grad;
  ctx.beginPath();
  ctx.arc(cx, cy, coreR, 0, Math.PI * 2);
  ctx.fill();
  const wave = DataRow.waveform * DATA_WIDTH;
  ctx.strokeStyle = css([0.25 + c2[0] * 0.75, 0.25 + c2[1] * 0.75, 0.25 + c2[2] * 0.75], 0.9);
  ctx.lineWidth = Math.max(1, unit * 0.006);
  ctx.beginPath();
  for (let k = 0; k <= 128; k++) {
    const turn = k / 128;
    const sample = data[wave + Math.min(511, Math.floor(turn * 511))];
    const r = coreR * (0.78 + 0.256 * sample);
    const a = rotation + turn * Math.PI * 2;
    const x = cx + Math.cos(a) * r;
    const y = cy - Math.sin(a) * r;
    if (k === 0) ctx.moveTo(x, y);
    else ctx.lineTo(x, y);
  }
  ctx.stroke();
}
