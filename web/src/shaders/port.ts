/** One Metal visualizer ported to GLSL ES 3.00 (docs/web-port.md). */
export interface VisualizerPort {
  /** Stable id, matching the Swift `IntenseKind` id of the look it ports (IntenseKind.swift), e.g. `"halo"`. */
  readonly id: string;
  readonly title: string;
  /** The Swift file holding the MSL this port was made from, relative to the repository root. */
  readonly metalSource: string;
  /**
   * SHA-256 of that file when the port was last brought up to date. The sync test fails when the Metal file changes,
   * so a Metal edit cannot silently leave its web twin behind: re-port the change, then record the new hash.
   */
  readonly metalSha256: string;
  /** The visualizer's GLSL: its helpers and `main`, compiled after FRAGMENT_PRELUDE. */
  readonly glsl: string;
}
