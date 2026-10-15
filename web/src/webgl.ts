import type { SoundRenderer } from "./renderer.js";
import { FRAGMENT_PRELUDE, PRESENT_SHADER, VERTEX_SHADER, visualizer, type VisualizerId } from "./shaders/index.js";
import type { SoundVisualState } from "./state.js";
import { DATA_ROWS, DATA_WIDTH, UNIFORM_NAMES, type ShaderInputs } from "./uniforms.js";

interface VisualProgram {
  program: WebGLProgram;
  uniforms: (WebGLUniformLocation | null)[];
  data: WebGLUniformLocation | null;
}

/** Thrown when the browser has no WebGL2 or a shader fails to build; the caller falls back to Canvas2D. */
export class WebGLUnavailableError extends Error {}

/**
 * The WebGL2 renderer. Each frame: upload the uniforms and the R32F data texture, draw the visualizer's fragment
 * shader over a full-screen triangle into a mipmapped scene texture, then present it to the canvas scaled by the luma
 * watchdog's gain (the Metal renderer's `WatchedSurface` and `intenseDimFragment`). Every other frame the scene's 1x1
 * mip is read back through a pixel-pack buffer and a fence, so the watchdog never stalls the GPU.
 */
export class WebGLRenderer implements SoundRenderer {
  readonly kind = "webgl2" as const;
  private readonly gl: WebGL2RenderingContext;
  private readonly programs = new Map<VisualizerId, VisualProgram>();
  private readonly present: WebGLProgram;
  private readonly presentScene: WebGLUniformLocation | null;
  private readonly presentGain: WebGLUniformLocation | null;
  private readonly vao: WebGLVertexArrayObject;
  private readonly dataTexture: WebGLTexture;
  private sceneTexture: WebGLTexture;
  private readonly sceneFramebuffer: WebGLFramebuffer;
  private readonly readFramebuffer: WebGLFramebuffer;
  private readonly packBuffer: WebGLBuffer;
  private readonly lumaBytes = new Uint8Array(4);
  private fence: WebGLSync | null = null;
  private pendingLuma: number | null = null;
  private frame = 0;
  private width = 0;
  private height = 0;
  private current: VisualizerId = "spectrum";

  constructor(private readonly canvas: HTMLCanvasElement) {
    const gl = canvas.getContext("webgl2", {
      alpha: false,
      antialias: false,
      depth: false,
      stencil: false,
      premultipliedAlpha: false,
      preserveDrawingBuffer: false,
      powerPreference: "default",
    });
    if (!gl) throw new WebGLUnavailableError("WebGL2 is not available");
    this.gl = gl;
    this.present = this.link(PRESENT_SHADER);
    this.presentScene = gl.getUniformLocation(this.present, "uScene");
    this.presentGain = gl.getUniformLocation(this.present, "uGain");
    this.vao = must(gl.createVertexArray());

    this.dataTexture = must(gl.createTexture());
    gl.bindTexture(gl.TEXTURE_2D, this.dataTexture);
    gl.texStorage2D(gl.TEXTURE_2D, 1, gl.R32F, DATA_WIDTH, DATA_ROWS);
    setFilters(gl, gl.NEAREST, gl.NEAREST);

    this.sceneTexture = must(gl.createTexture());
    this.sceneFramebuffer = must(gl.createFramebuffer());
    this.readFramebuffer = must(gl.createFramebuffer());
    this.packBuffer = must(gl.createBuffer());
    gl.bindBuffer(gl.PIXEL_PACK_BUFFER, this.packBuffer);
    gl.bufferData(gl.PIXEL_PACK_BUFFER, 4, gl.STREAM_READ);
    gl.bindBuffer(gl.PIXEL_PACK_BUFFER, null);
    this.resize(canvas.width || 1, canvas.height || 1);
    this.setVisual(this.current);
  }

  setVisual(id: VisualizerId): void {
    this.current = id;
    if (this.programs.has(id)) return;
    const program = this.link(FRAGMENT_PRELUDE + visualizer(id).glsl);
    const gl = this.gl;
    this.programs.set(id, {
      program,
      uniforms: UNIFORM_NAMES.map((name) => gl.getUniformLocation(program, `u.${name}`)),
      data: gl.getUniformLocation(program, "uData"),
    });
  }

  resize(width: number, height: number): void {
    const gl = this.gl;
    width = Math.max(1, Math.floor(width));
    height = Math.max(1, Math.floor(height));
    if (width === this.width && height === this.height) return;
    this.width = width;
    this.height = height;
    this.canvas.width = width;
    this.canvas.height = height;
    // A fresh immutable texture of the new size, with its full mip chain (the last level is the 1x1 luma).
    gl.deleteTexture(this.sceneTexture);
    this.sceneTexture = must(gl.createTexture());
    gl.bindTexture(gl.TEXTURE_2D, this.sceneTexture);
    const levels = Math.floor(Math.log2(Math.max(width, height))) + 1;
    gl.texStorage2D(gl.TEXTURE_2D, levels, gl.RGBA8, width, height);
    setFilters(gl, gl.LINEAR, gl.LINEAR);
    gl.bindFramebuffer(gl.FRAMEBUFFER, this.sceneFramebuffer);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, this.sceneTexture, 0);
    gl.bindFramebuffer(gl.READ_FRAMEBUFFER, this.readFramebuffer);
    gl.framebufferTexture2D(gl.READ_FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, this.sceneTexture, levels - 1);
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    this.dropFence();
  }

  draw(inputs: ShaderInputs, _state: SoundVisualState, gain: number): void {
    const gl = this.gl;
    const visual = this.programs.get(this.current);
    if (!visual || gl.isContextLost()) return;
    this.frame += 1;
    this.pollFence();

    gl.bindVertexArray(this.vao);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, this.dataTexture);
    gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, DATA_WIDTH, DATA_ROWS, gl.RED, gl.FLOAT, inputs.data);

    gl.bindFramebuffer(gl.FRAMEBUFFER, this.sceneFramebuffer);
    gl.viewport(0, 0, this.width, this.height);
    gl.useProgram(visual.program);
    for (let i = 0; i < visual.uniforms.length; i++) gl.uniform4fv(visual.uniforms[i], inputs.uniforms, i * 4, 4);
    gl.uniform1i(visual.data, 0);
    gl.drawArrays(gl.TRIANGLES, 0, 3);

    // Every other frame: reduce the scene to one pixel and start an asynchronous read of it.
    const measure = this.frame % 2 === 0 && this.fence === null;
    gl.bindTexture(gl.TEXTURE_2D, this.sceneTexture);
    if (measure) {
      gl.generateMipmap(gl.TEXTURE_2D);
      gl.bindFramebuffer(gl.READ_FRAMEBUFFER, this.readFramebuffer);
      gl.bindBuffer(gl.PIXEL_PACK_BUFFER, this.packBuffer);
      gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, 0);
      gl.bindBuffer(gl.PIXEL_PACK_BUFFER, null);
      this.fence = gl.fenceSync(gl.SYNC_GPU_COMMANDS_COMPLETE, 0);
    }

    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    gl.viewport(0, 0, this.width, this.height);
    gl.useProgram(this.present);
    gl.uniform1i(this.presentScene, 0);
    gl.uniform1f(this.presentGain, gain);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
    gl.bindVertexArray(null);
  }

  takeLuma(): number | null {
    this.pollFence();
    const luma = this.pendingLuma;
    this.pendingLuma = null;
    return luma;
  }

  destroy(): void {
    const gl = this.gl;
    this.dropFence();
    for (const p of this.programs.values()) gl.deleteProgram(p.program);
    this.programs.clear();
    gl.deleteProgram(this.present);
    gl.deleteTexture(this.dataTexture);
    gl.deleteTexture(this.sceneTexture);
    gl.deleteFramebuffer(this.sceneFramebuffer);
    gl.deleteFramebuffer(this.readFramebuffer);
    gl.deleteBuffer(this.packBuffer);
    gl.deleteVertexArray(this.vao);
  }

  private pollFence(): void {
    const gl = this.gl;
    if (!this.fence) return;
    const status = gl.clientWaitSync(this.fence, 0, 0);
    if (status === gl.TIMEOUT_EXPIRED) return;
    this.dropFence();
    if (status === gl.WAIT_FAILED) return;
    gl.bindBuffer(gl.PIXEL_PACK_BUFFER, this.packBuffer);
    gl.getBufferSubData(gl.PIXEL_PACK_BUFFER, 0, this.lumaBytes);
    gl.bindBuffer(gl.PIXEL_PACK_BUFFER, null);
    const b = this.lumaBytes;
    this.pendingLuma = (b[0] + b[1] + b[2]) / (3 * 255);
  }

  private dropFence(): void {
    if (this.fence) this.gl.deleteSync(this.fence);
    this.fence = null;
  }

  private link(fragmentSource: string): WebGLProgram {
    const gl = this.gl;
    const vertex = compile(gl, gl.VERTEX_SHADER, VERTEX_SHADER);
    const fragment = compile(gl, gl.FRAGMENT_SHADER, fragmentSource);
    const program = must(gl.createProgram());
    gl.attachShader(program, vertex);
    gl.attachShader(program, fragment);
    gl.linkProgram(program);
    gl.deleteShader(vertex);
    gl.deleteShader(fragment);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
      const log = gl.getProgramInfoLog(program);
      gl.deleteProgram(program);
      throw new WebGLUnavailableError(`Program link failed: ${log}`);
    }
    return program;
  }
}

function compile(gl: WebGL2RenderingContext, type: number, source: string): WebGLShader {
  const shader = must(gl.createShader(type));
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
    const log = gl.getShaderInfoLog(shader);
    gl.deleteShader(shader);
    throw new WebGLUnavailableError(`Shader compile failed: ${log}`);
  }
  return shader;
}

function setFilters(gl: WebGL2RenderingContext, min: number, mag: number): void {
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, min);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, mag);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
}

function must<T>(value: T | null): T {
  if (value === null) throw new WebGLUnavailableError("WebGL resource allocation failed");
  return value;
}
