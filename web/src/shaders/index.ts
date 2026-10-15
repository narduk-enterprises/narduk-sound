import { halo } from "./halo.js";
import type { VisualizerPort } from "./port.js";
import { scope } from "./scope.js";
import { spectrum } from "./spectrum.js";

export { FRAGMENT_PRELUDE, PRESENT_SHADER, VERTEX_SHADER } from "./common.js";
export type { VisualizerPort } from "./port.js";

/** Every ported visualizer, in gallery order. */
export const VISUALIZERS: readonly VisualizerPort[] = [spectrum, scope, halo];

export type VisualizerId = VisualizerPort["id"];

export function visualizer(id: VisualizerId): VisualizerPort {
  const port = VISUALIZERS.find((v) => v.id === id);
  if (!port) throw new Error(`Unknown visualizer ${id}`);
  return port;
}
