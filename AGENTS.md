# NardukSound: agent notes

Read `README.md` for the products and `docs/sound-contract.md` for the contract between them.

- The gate is `python3 scripts/swift-quality.py`: lint, `swift test`, the release-mode allocation suites, the CLI and a
  consumer that resolves a version tag. CI runs it on Linux and macOS and builds `Examples/SoundGallery`.
- Releases are SwiftPM tags `vX.Y.Z` on `main`; add the entry to `CHANGELOG.md` in the same PR.
- Per-frame state (the playhead, the engine's frame) is polled inside a `TimelineView` or `MTKView` clock and never
  observed (Wirewatcher #65).
- Apps that use this package live in their own repositories (beat-blaster, data-beats, wirewatcher, buildbeat). An app
  change never lands here; `Examples/SoundGallery` is the package's own test bench.

Issue labels: `bug`, `enhancement`, `documentation`; `P0-critical` to `P3-low`.
