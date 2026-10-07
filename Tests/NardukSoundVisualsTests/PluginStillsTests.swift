#if canImport(Metal)
    import Foundation
    import Metal
    import NardukSoundAnalysis
    import Testing

    @testable import NardukSoundVisuals

    /// Renders every `.metal` plugin in `NARDUK_PLUGIN_DIR` to PPM stills in `NARDUK_INTENSE_DEMO_DIR` (a plugin's
    /// headless review, narduk-libs#1665); a plugin that fails to compile writes its error to `<id>.error.txt`.
    /// Never runs in CI.
    @MainActor @Suite struct PluginStillsTests {
        @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "no Metal device on this host"))
        func writesPluginStillsWhenAskedTo() throws {
            let env = ProcessInfo.processInfo.environment
            guard let source = env["NARDUK_PLUGIN_DIR"], let directory = env["NARDUK_INTENSE_DEMO_DIR"] else { return }
            let renderer = try IntenseVisualizerTests.renderer()
            let library = IntensePluginLibrary(directory: URL(fileURLWithPath: source), renderer: renderer)
            library.reload()
            for entry in library.entries {
                guard let kind = entry.kind, entry.error == nil else {
                    try (entry.error ?? "no kind").write(
                        toFile: "\(directory)/\(entry.id).error.txt", atomically: true, encoding: .utf8)
                    continue
                }
                let (width, height) = (640, 360)
                let state = SoundVisualState(seed: 7)
                var limiter = IntenseFlashLimiter()
                var now = 1.0
                var frame = 0
                func step() {
                    let input = SoundVisualInput(
                        frame: Script.frame(UInt64(frame + 1), level: 0.8),
                        music: Script.music(
                            step: frame / 4, kicks: frame % 15 == 0 ? 1 : 0, snares: frame % 30 == 15 ? 1 : 0))
                    state.update(input, now: now)
                    now += 1.0 / 60
                    frame += 1
                }
                for _ in 0..<60 { step() }
                for shot in 0..<4 {
                    let pixels = try #require(
                        renderer.renderOffscreen(
                            kind, state: state, width: width, height: height, frames: shot == 0 ? 90 : 7,
                            limiter: &limiter, advance: step))
                    var ppm = Data("P6\n\(width) \(height)\n255\n".utf8)
                    var index = 0
                    while index < pixels.count {
                        ppm.append(contentsOf: [pixels[index + 2], pixels[index + 1], pixels[index]])
                        index += 4
                    }
                    try ppm.write(to: URL(fileURLWithPath: "\(directory)/\(kind.id)-\(shot).ppm"))
                }
                // The same picture under two palette looks: every visualizer must follow the palette.
                for preset in [SoundPalettePreset.toxic, .candy, .ice] {
                    state.look = SoundPaletteLook(preset: preset)
                    let pixels = try #require(
                        renderer.renderOffscreen(
                            kind, state: state, width: width, height: height, frames: 60, limiter: &limiter,
                            advance: step))
                    var ppm = Data("P6\n\(width) \(height)\n255\n".utf8)
                    var index = 0
                    while index < pixels.count {
                        ppm.append(contentsOf: [pixels[index + 2], pixels[index + 1], pixels[index]])
                        index += 4
                    }
                    try ppm.write(to: URL(fileURLWithPath: "\(directory)/\(kind.id)-\(preset.rawValue).ppm"))
                }
                state.look = .neutral
            }
        }
    }
#endif
