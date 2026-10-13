import { audioTerrain } from "./audioTerrain.js";
import { bioluminescentSea } from "./bioluminescentSea.js";
import { blackHole } from "./blackHole.js";
import { flameSun } from "./flameSun.js";
import { flower } from "./flower.js";
import { geometricChaos } from "./geometricChaos.js";
import { halo } from "./halo.js";
import { hyperspaceLasers } from "./hyperspaceLasers.js";
import { jellyfish } from "./jellyfish.js";
import { kaleidoscope } from "./kaleidoscope.js";
import { liquidSplash } from "./liquidSplash.js";
import { mirror } from "./mirror.js";
import type { CustomVisualizer, VisualizerPort } from "./port.js";
import { scope } from "./scope.js";
import { spectrum } from "./spectrum.js";
import { sun } from "./sun.js";
import { vortex } from "./vortex.js";

export { FRAGMENT_PRELUDE, PRESENT_SHADER, VERTEX_SHADER } from "./common.js";
export type { CustomVisualizer, VisualizerPort } from "./port.js";

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
  sun,
  flameSun,
  jellyfish,
  flower,
  liquidSplash,
  bioluminescentSea,
  mirror,
];

/** An `IntenseKind` id (`VISUALIZERS` lists the ones with a port). */
export type VisualizerId = string;

const registered: CustomVisualizer[] = [];

/** Adds an app's own look (or replaces the registered one with its id). It comes first in `visualizers()`. */
export function registerVisualizer(look: CustomVisualizer): void {
  if (VISUALIZERS.some((v) => v.id === look.id)) throw new Error(`${look.id} is a built-in visualizer`);
  const at = registered.findIndex((v) => v.id === look.id);
  if (at >= 0) registered[at] = look;
  else registered.push(look);
}

/** The registered looks, then the ports: the picker's order. */
export function visualizers(): readonly CustomVisualizer[] {
  return [...registered, ...VISUALIZERS];
}

export function visualizer(id: VisualizerId): CustomVisualizer {
  const look = registered.find((v) => v.id === id) ?? VISUALIZERS.find((v) => v.id === id);
  if (!look) throw new Error(`Unknown visualizer ${id}`);
  return look;
}
