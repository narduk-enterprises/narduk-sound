/**
 * A look the WebGL renderer can draw: its GLSL (helpers and `main`, compiled after FRAGMENT_PRELUDE) and, optionally,
 * an image it samples, premultiplied, as `uniform sampler2D uImage` (a URL the page may read: same origin or CORS). Apps
 * add their own with `registerVisualizer`; until the image loads `uImage` reads transparent black.
 */
export interface CustomVisualizer {
  /** Stable id, unique across the built-in ports and every registered look. */
  readonly id: string;
  readonly title: string;
  readonly glsl: string;
  readonly image?: string;
}

/** One Metal visualizer ported to GLSL ES 3.00 (docs/web-port.md). */
export interface VisualizerPort extends CustomVisualizer {
  /** Matches the Swift `IntenseKind` id of the look it ports (IntenseKind.swift), e.g. `"halo"`. */
  readonly id: string;
  /** The Swift file holding the MSL this port was made from, relative to the repository root. */
  readonly metalSource: string;
  /**
   * SHA-256 of that file when the port was last brought up to date. The sync test fails when the Metal file changes,
   * so a Metal edit cannot silently leave its web twin behind: re-port the change, then record the new hash.
   */
  readonly metalSha256: string;
}
