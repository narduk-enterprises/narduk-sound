import { audioTerrain } from "./audioTerrain.js";
import { blackHole } from "./blackHole.js";
import { geometricChaos } from "./geometricChaos.js";
import { halo } from "./halo.js";
import { hyperspaceLasers } from "./hyperspaceLasers.js";
import { kaleidoscope } from "./kaleidoscope.js";
import type { VisualizerPort } from "./port.js";
import { scope } from "./scope.js";
import { spectrum } from "./spectrum.js";
import { vortex } from "./vortex.js";

export { FRAGMENT_PRELUDE, PRESENT_SHADER, VERTEX_SHADER } from "./common.js";
export type { VisualizerPort } from "./port.js";

/** Every ported visualizer, in gallery order. */
export const VISUALIZERS: readonly VisualizerPort[] = [
  spectrum,
  scope,
  halo,
  vortex,
  hyperspaceLasers,
  kaleidoscope,
  blackHole,
  geometricChaos,
  audioTerrain,
];

/** An `IntenseKind` id (`VISUALIZERS` lists the ones with a port). */
export type VisualizerId = string;

export function visualizer(id: VisualizerId): VisualizerPort {
  const port = VISUALIZERS.find((v) => v.id === id);
  if (!port) throw new Error(`Unknown visualizer ${id}`);
  return port;
}
