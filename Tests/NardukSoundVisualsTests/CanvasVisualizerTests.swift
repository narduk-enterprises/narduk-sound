#if canImport(SwiftUI) && canImport(AppKit)
    import AppKit
    import NardukMusicCore
    import NardukSoundAnalysis
    import SwiftUI
    import Testing

    @testable import NardukSoundVisuals

    /// Golden images for the Canvas visualizers (narduk-libs#1571). A scripted `SoundFrame` + `MusicContext` sequence at
    /// a fixed seed and `now` series drives a `SoundVisualState`; each visualizer renders to a 480 x 270 bitmap, which is
    /// reduced to a 16 x 9 grid of mean luma and compared with a committed grid within a tolerance (blur filters and
    /// font hinting differ a little between macOS releases, so exact bytes are the wrong thing to pin).
    /// A change to a look is deliberate: listen with the gallery, then update the goldens from the failure message.
    @MainActor @Suite struct CanvasVisualizerTests {
        static let width = 480
        static let height = 270
        static let columns = 16
        static let rows = 9
        /// Mean absolute difference, in 0 ... 255 luma, a grid may drift before the test fails.
        static let tolerance = 3.0

        /// A busy mid-song state: a kick on every beat, a snare on the backbeat, a wobble, a drop.
        static func busyState(silent: Bool = false, look: SoundPaletteLook = .neutral) -> SoundVisualState {
            let state = SoundVisualState(seed: 42)
            state.look = look
            var now = 100.0
            var notes = NoteCounters()
            // A rising C minor arpeggio, one note every ten frames, each held for twenty-five.
            let arpeggio = [48, 55, 60, 63, 67, 72, 67, 63, 60, 55, 51, 58, 62, 65, 70]
            for i in 0..<150 {
                if i % 10 == 0 { notes.record(arpeggio[(i / 10) % arpeggio.count]) }
                var held = NoteSet()
                for back in 0..<3 {
                    let started = (i / 10 - back) * 10
                    if started >= 0, i - started < 25 { held.insert(arpeggio[(started / 10) % arpeggio.count]) }
                }
                let frame =
                    silent
                    ? SoundFrame(sequence: UInt64(i + 1), time: Double(i) / 60)
                    : Script.frame(UInt64(i + 1), level: 0.55 + 0.3 * sin(Float(i) / 9))
                var counts = HitCounters()
                for _ in 0..<(i / 15) { counts.record(.kick) }
                for _ in 0..<(i / 30) { counts.record(.snare) }
                for _ in 0..<(i / 7) { counts.record(.hat) }
                if i > 60 { for _ in 0..<((i - 60) / 20) { counts.record(.wobble) } }
                // A burst on the last two frames, so the pads are mid-flash when the image is taken.
                if i >= 147 { for hit in [Instrument.kick, .snare, .laser, .glitch, .keys] { counts.record(hit) } }
                let music = MusicContext(
                    hitCounts: counts, step: i / 4, section: i < 50 ? .build : .drop, energy: 0.85,
                    wobblePhase: Float(i % 40) / 40, wobbleCutoff: 0.5 + 0.35 * sin(Float(i) / 11), isRunning: true,
                    heldNotes: held, noteCounts: notes)
                state.update(SoundVisualInput(frame: frame, music: silent ? nil : music), now: now)
                now += 1.0 / 60
            }
            return state
        }

        /// The kind rendered over a dark backdrop, as the grid of mean luma.
        static func grid(_ kind: SoundVisualizerKind, _ state: SoundVisualState, dump: Bool = false) throws -> [Int] {
            let content = Canvas { context, size in
                SoundVisualizers.draw(kind, &context, size, state)
            }
            .frame(width: CGFloat(width), height: CGFloat(height))
            .background(Color(red: 0.03, green: 0.03, blue: 0.06))
            let renderer = ImageRenderer(content: content)
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            if dump, let dir = ProcessInfo.processInfo.environment["NARDUK_CANVAS_DUMP"] {
                let rep = NSBitmapImageRep(cgImage: image)
                try rep.representation(using: .png, properties: [:])?.write(
                    to: URL(fileURLWithPath: dir).appendingPathComponent("\(kind.rawValue).png"))
            }
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let context = try #require(
                CGContext(
                    data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let cellW = width / columns
            let cellH = height / rows
            var out: [Int] = []
            for row in 0..<rows {
                for column in 0..<columns {
                    var sum = 0.0
                    for y in (row * cellH)..<((row + 1) * cellH) {
                        for x in (column * cellW)..<((column + 1) * cellW) {
                            let i = (y * width + x) * 4
                            sum +=
                                0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722
                                * Double(pixels[i + 2])
                        }
                    }
                    out.append(Int((sum / Double(cellW * cellH)).rounded()))
                }
            }
            return out
        }

        static func drift(_ a: [Int], _ b: [Int]) -> Double {
            guard a.count == b.count, !a.isEmpty else { return .infinity }
            return Double(zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) }) / Double(a.count)
        }

        @Test(arguments: SoundVisualizerKind.allCases)
        func eachVisualizerMatchesItsGoldenImage(_ kind: SoundVisualizerKind) throws {
            let actual = try Self.grid(kind, Self.busyState(), dump: true)
            let golden = try #require(CanvasGoldens.darwin[kind], "no golden recorded for \(kind.rawValue)")
            if golden.isEmpty || Self.drift(actual, golden) > Self.tolerance {
                Issue.record(
                    "\(kind.rawValue) drifted \(golden.isEmpty ? .infinity : Self.drift(actual, golden)) from its golden"
                )
                print("GOLDEN \(kind.rawValue): \(actual)")
            }
        }

        @Test(arguments: SoundVisualizerKind.allCases)
        func aVisualizerShowsSomethingWhenTheSoundIsLoud(_ kind: SoundVisualizerKind) throws {
            let loud = try Self.grid(kind, Self.busyState())
            let blank = try Self.grid(kind, SoundVisualState(seed: 42))
            #expect(Self.drift(loud, blank) > 1.0, "\(kind.rawValue) looks the same loud and untouched")
        }

        @Test(arguments: SoundVisualizerKind.allCases)
        func aSilentSourceDrawsWithoutMusic(_ kind: SoundVisualizerKind) throws {
            let grid = try Self.grid(kind, Self.busyState(silent: true))
            #expect(grid.count == Self.columns * Self.rows)
        }

        @Test func everyInstrumentHasAPadPositionInsideThePalette() {
            for instrument in Instrument.allCases {
                let position = SoundVisualizers.padPosition(instrument)
                #expect(position >= 0 && position <= 1)
            }
        }

        @Test func aRoomyCardKeepsTheLooseLabelledPads() {
            let layout = SoundVisualizers.PadLayout.fit(
                count: Instrument.allCases.count, in: CGSize(width: 480, height: 270))
            #expect(layout.showsLabels)
            #expect(layout.gap == 8)
        }

        @Test func aShortCardPacksPadsWithoutOverlappingLabels() {
            let count = Instrument.allCases.count
            for size in [
                CGSize(width: 380, height: 90), CGSize(width: 300, height: 60),
                CGSize(width: 200, height: 40),
            ] {
                let layout = SoundVisualizers.PadLayout.fit(count: count, in: size)
                #expect(layout.columns * layout.rows >= count, "\(size)")
                let h = (size.height - layout.gap * CGFloat(layout.rows + 1)) / CGFloat(layout.rows)
                #expect(h > 0, "\(size)")
                // Labels only when a line of text fits in a pad: never stacked on top of each other.
                #expect(
                    !layout.showsLabels || h >= SoundVisualizers.PadLayout.minLabelHeight, "\(size)"
                )
            }
            #expect(
                SoundVisualizers.PadLayout.fit(count: count, in: CGSize(width: 380, height: 90))
                    .showsLabels)
        }

        @Test func theScopeTriggersOnTheFirstRisingZeroCrossing() {
            var wave = [Float](repeating: 0.4, count: SoundFrame.waveformCount)
            wave[10] = -0.3  // falls below zero at 10, crosses up at 11
            wave[11] = 0.2
            let start = wave.withUnsafeBufferPointer { SoundVisualizers.scopeTrigger($0) }
            #expect(start == 11)
            let flat = [Float](repeating: 0.4, count: SoundFrame.waveformCount)
            #expect(flat.withUnsafeBufferPointer { SoundVisualizers.scopeTrigger($0) } == 0)
        }

        @Test func theMirrorWidensBassBandsInADropAndNothingElse() {
            #expect(SoundVisualizers.mirrorWeight(0, 0) == 1)
            #expect(SoundVisualizers.mirrorWeight(0, 1) > 2.5)
            #expect(SoundVisualizers.mirrorWeight(12, 1) == 1)
            #expect(SoundVisualizers.mirrorWeight(40, 1) == 1)
        }
    }

    /// Mean-luma grids (16 x 9, row-major) recorded on macOS.
    enum CanvasGoldens {
        static let darwin: [SoundVisualizerKind: [Int]] = [
            .spectrum: [
                9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
                29, 32, 20, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
                9, 9, 21, 32, 32, 12, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
                48, 22, 11, 9, 9, 29, 32, 26, 9, 9, 9, 9, 9, 9, 9, 9,
                175, 195, 161, 117, 74, 34, 13, 15, 32, 32, 19, 9, 9, 9, 9, 9,
                151, 176, 176, 176, 175, 171, 151, 116, 81, 47, 33, 34, 32, 11, 9, 9,
                121, 139, 139, 139, 139, 139, 137, 137, 137, 136, 132, 108, 80, 73, 49, 27,
                37, 41, 41, 41, 41, 41, 40, 39, 38, 38, 37, 37, 36, 35, 33, 24,
                11, 11, 10, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
            ],
            .scope: [
                9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
                9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
                9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
                25, 28, 17, 9, 9, 20, 27, 22, 9, 9, 14, 29, 27, 9, 9, 9,
                18, 9, 28, 9, 12, 26, 9, 23, 15, 9, 29, 9, 16, 22, 9, 26,
                9, 9, 11, 30, 29, 9, 9, 9, 28, 29, 13, 9, 9, 23, 27, 19,
                9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
                9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
                9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
            ],
            .wobbleMeter: [
                9, 9, 24, 48, 47, 48, 35, 9, 9, 15, 19, 24, 9, 9, 9, 9,
                9, 38, 38, 9, 9, 9, 26, 51, 9, 14, 18, 23, 9, 9, 9, 9,
                19, 42, 9, 9, 9, 9, 9, 22, 39, 57, 85, 24, 9, 9, 9, 9,
                47, 9, 9, 9, 9, 9, 9, 9, 42, 95, 148, 190, 10, 9, 9, 9,
                54, 24, 32, 35, 21, 9, 9, 9, 15, 93, 148, 216, 11, 9, 9, 9,
                66, 30, 12, 9, 9, 9, 9, 9, 15, 91, 145, 211, 11, 9, 9, 9,
                19, 42, 9, 9, 25, 12, 9, 11, 14, 89, 140, 205, 10, 9, 9, 9,
                9, 31, 9, 11, 14, 13, 9, 12, 9, 86, 134, 197, 10, 9, 9, 9,
                9, 9, 9, 9, 9, 9, 9, 9, 9, 21, 34, 48, 9, 9, 9, 9,
            ],
            .pads: [
                99, 122, 122, 88, 95, 96, 69, 70, 70, 45, 24, 24, 29, 63, 63, 52,
                122, 160, 150, 111, 134, 127, 88, 96, 93, 57, 36, 38, 37, 91, 105, 63,
                48, 61, 62, 87, 117, 117, 62, 43, 43, 47, 74, 74, 56, 43, 42, 34,
                27, 45, 33, 99, 150, 145, 69, 45, 43, 56, 113, 123, 78, 37, 48, 29,
                22, 28, 28, 56, 81, 81, 41, 30, 30, 50, 106, 106, 72, 30, 30, 24,
                24, 38, 32, 31, 51, 48, 29, 47, 46, 64, 130, 133, 94, 41, 40, 36,
                21, 26, 26, 23, 29, 29, 23, 28, 28, 45, 87, 87, 61, 21, 21, 18,
                44, 49, 48, 44, 47, 46, 27, 36, 37, 34, 49, 48, 39, 9, 9, 9,
                23, 27, 27, 23, 27, 27, 22, 25, 25, 22, 27, 27, 20, 9, 9, 9,
            ],
            .mirror: [
                7, 9, 10, 14, 21, 14, 29, 30, 30, 29, 14, 15, 14, 10, 9, 7,
                8, 10, 19, 41, 29, 58, 51, 72, 69, 51, 44, 14, 17, 12, 10, 8,
                9, 11, 13, 20, 46, 53, 66, 68, 58, 67, 50, 49, 20, 13, 11, 9,
                10, 12, 32, 48, 57, 93, 150, 173, 170, 151, 95, 59, 46, 34, 12, 10,
                15, 49, 68, 92, 111, 136, 163, 180, 180, 164, 136, 114, 95, 77, 50, 16,
                55, 93, 99, 108, 101, 119, 134, 158, 151, 138, 119, 98, 100, 103, 91, 56,
                31, 38, 43, 48, 54, 61, 80, 89, 89, 81, 61, 53, 49, 43, 38, 31,
                18, 19, 21, 26, 40, 53, 61, 67, 68, 62, 53, 40, 26, 21, 19, 19,
                16, 17, 18, 21, 25, 33, 43, 50, 51, 43, 34, 25, 21, 18, 17, 16,
            ],
            .halo: [
                9, 10, 12, 13, 18, 22, 23, 25, 25, 23, 22, 18, 13, 12, 10, 9,
                9, 11, 13, 17, 28, 30, 54, 59, 56, 45, 27, 22, 17, 13, 11, 9,
                10, 12, 20, 44, 41, 76, 78, 101, 94, 64, 54, 25, 21, 14, 12, 10,
                10, 12, 14, 24, 44, 83, 108, 121, 113, 115, 72, 38, 23, 15, 12, 10,
                10, 12, 15, 28, 54, 98, 122, 136, 132, 119, 77, 51, 22, 17, 12, 10,
                10, 12, 14, 30, 46, 113, 132, 123, 126, 112, 77, 43, 30, 25, 12, 10,
                10, 12, 15, 42, 40, 101, 134, 140, 126, 108, 65, 32, 23, 18, 12, 10,
                9, 11, 13, 17, 30, 43, 101, 114, 100, 65, 37, 22, 17, 13, 11, 9,
                9, 10, 12, 13, 18, 30, 33, 35, 36, 31, 24, 18, 13, 12, 10, 9,
            ],
            .phosphor: [
                7, 9, 12, 14, 19, 22, 20, 20, 22, 20, 21, 20, 14, 12, 9, 7,
                8, 11, 14, 18, 26, 21, 36, 36, 37, 36, 21, 21, 19, 14, 11, 8,
                9, 12, 21, 43, 32, 52, 29, 51, 50, 29, 38, 20, 22, 15, 12, 9,
                10, 13, 16, 22, 26, 34, 67, 82, 63, 68, 32, 28, 22, 16, 13, 10,
                11, 14, 18, 22, 34, 28, 88, 57, 35, 80, 28, 35, 21, 19, 14, 11,
                10, 13, 16, 22, 25, 35, 73, 82, 83, 67, 33, 28, 28, 26, 13, 10,
                9, 12, 16, 40, 25, 37, 40, 74, 70, 49, 38, 21, 23, 19, 12, 9,
                8, 11, 14, 18, 21, 21, 34, 36, 37, 35, 21, 21, 18, 14, 11, 8,
                7, 10, 13, 15, 19, 23, 20, 21, 22, 20, 22, 20, 15, 13, 10, 7,
            ],
            .pianoRoll: [
                7, 8, 8, 8, 10, 11, 12, 13, 14, 15, 44, 45, 17, 17, 17, 27,
                8, 9, 9, 10, 11, 12, 14, 15, 16, 17, 30, 31, 20, 20, 20, 61,
                10, 11, 11, 12, 13, 15, 16, 17, 18, 28, 60, 62, 31, 23, 27, 44,
                7, 8, 8, 9, 11, 12, 13, 15, 16, 38, 36, 36, 41, 22, 53, 60,
                8, 9, 9, 11, 12, 14, 15, 16, 37, 73, 27, 27, 76, 47, 38, 38,
                9, 10, 11, 12, 13, 15, 16, 17, 37, 30, 21, 22, 33, 60, 59, 35,
                7, 8, 8, 9, 10, 12, 13, 15, 31, 25, 18, 19, 28, 37, 21, 31,
                10, 11, 11, 12, 13, 14, 16, 19, 24, 19, 20, 21, 22, 46, 30, 33,
                8, 9, 9, 9, 11, 12, 13, 19, 32, 16, 17, 18, 18, 18, 18, 28,
            ],
            .pitchWheel: [
                9, 10, 11, 12, 13, 14, 14, 15, 15, 14, 14, 13, 12, 11, 10, 9,
                9, 10, 12, 13, 14, 15, 20, 35, 34, 21, 15, 14, 13, 12, 10, 9,
                10, 11, 12, 13, 23, 66, 35, 41, 41, 27, 27, 19, 13, 12, 11, 10,
                10, 11, 12, 14, 17, 122, 141, 36, 34, 107, 60, 15, 14, 12, 11, 10,
                10, 11, 13, 14, 19, 19, 31, 50, 41, 47, 18, 21, 14, 13, 11, 10,
                10, 11, 12, 14, 15, 16, 24, 39, 48, 33, 16, 15, 14, 12, 11, 10,
                10, 11, 12, 13, 18, 18, 17, 23, 59, 93, 21, 16, 13, 12, 11, 10,
                9, 10, 12, 13, 14, 15, 19, 18, 27, 43, 15, 14, 13, 12, 10, 9,
                9, 10, 11, 12, 13, 14, 14, 15, 15, 14, 14, 13, 12, 11, 10, 9,
            ],
        ]
    }
#endif
