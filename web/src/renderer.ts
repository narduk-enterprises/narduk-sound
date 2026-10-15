import type { VisualizerId } from "./shaders/index.js";
import type { SoundVisualState } from "./state.js";
import type { ShaderInputs } from "./uniforms.js";

/** What draws a frame: the WebGL2 port of the Metal shaders, or the Canvas2D fallback. */
export interface SoundRenderer {
  readonly kind: "webgl2" | "canvas2d";
  /** Prepares `id` (compiles its program on first use). */
  setVisual(id: VisualizerId): void;
  /** Resizes the backing store, in device pixels. */
  resize(width: number, height: number): void;
  /** Draws one frame from `inputs` (filled from `state`), scaled by the luma watchdog's `gain`. */
  draw(inputs: ShaderInputs, state: SoundVisualState, gain: number): void;
  /**
   * The mean luma (0 ... 1) of a recent finished frame, or null when none is ready. Reads back asynchronously where
   * it can, so measuring never stalls the frame.
   */
  takeLuma(): number | null;
  destroy(): void;
}
