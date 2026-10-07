#if canImport(SwiftUI) && canImport(AppKit)
    import Foundation
    import simd
    import NardukMusicCore
    import NardukSoundAnalysis
    import Testing

    @testable import NardukSoundVisuals

    /// The shared palette look: the default changes nothing, every preset and a random roll change what every kind draws,
    /// and no palette gets past the flash rules (A16, Logan: "knobs for tuning color").
    @MainActor @Suite struct SoundPaletteLookTests {
        static let looks: [(String, SoundPaletteLook)] = [
            ("sunset", SoundPaletteLook(preset: .sunset)),
            ("ocean", SoundPaletteLook(preset: .ocean)),
            ("hue +120", SoundPaletteLook(hueShift: 120)),
            ("random 7", SoundPaletteLook.random(seed: 7)),
        ]

        @Test func theNeutralLookIsTheIdentity() {
            #expect(SoundPaletteLook.neutral.isNeutral)
            #expect(SoundPaletteLook(preset: .neon).isNeutral)
            let plain = CanvasVisualizerTests.busyState()
            let neutral = CanvasVisualizerTests.busyState(look: .neutral)
            #expect(plain.palette == neutral.palette)
        }

        @Test func aPresetChangesThePaletteAndNeonDoesNot() {
            let base = CanvasVisualizerTests.busyState().palette
            #expect(CanvasVisualizerTests.busyState(look: SoundPaletteLook(preset: .neon)).palette == base)
            for preset in SoundPalettePreset.allCases where preset != .neon {
                let palette = CanvasVisualizerTests.busyState(look: SoundPaletteLook(preset: preset)).palette
                #expect(palette != base, "\(preset.title) left the palette unchanged")
            }
        }

        @Test func theKnobsMoveTheColors() {
            let base = CanvasVisualizerTests.busyState().palette
            for look in [
                SoundPaletteLook(hueShift: 90), SoundPaletteLook(saturation: 0), SoundPaletteLook(brightness: 0.5),
            ] {
                #expect(CanvasVisualizerTests.busyState(look: look).palette != base, "\(look) changed nothing")
            }
            // Zero saturation is grey: the three channels agree.
            let grey = CanvasVisualizerTests.busyState(look: SoundPaletteLook(saturation: 0)).palette.c0
            #expect(abs(grey.x - grey.y) < 1e-4 && abs(grey.y - grey.z) < 1e-4)
        }

        @Test func aCycleDriftsTheHueWithTime() {
            let look = SoundPaletteLook(colors: SoundPalettePreset.sunset.colors, cycle: 30)
            let early = look.applied(to: SoundPalette(c0: .zero, c1: .zero, c2: .zero), time: 0)
            let later = look.applied(to: SoundPalette(c0: .zero, c1: .zero, c2: .zero), time: 3)
            #expect(early == SoundPalettePreset.sunset.colors)
            #expect(later != early)
        }

        @Test func randomIsDeterministicAndVaried() {
            #expect(SoundPaletteLook.random(seed: 99) == SoundPaletteLook.random(seed: 99))
            let seeds = (0..<20).map { SoundPaletteLook.random(seed: UInt64($0)).colors }
            #expect(Set(seeds.map { "\($0!.c0)" }).count > 15, "random palettes barely vary")
            for seed in 0..<200 {
                let colors = SoundPaletteLook.random(seed: UInt64(seed)).colors!
                for c in [colors.c0, colors.c1, colors.c2] {
                    #expect(c.x >= 0 && c.x <= 1 && c.y >= 0 && c.y <= 1 && c.z >= 0 && c.z <= 1)
                }
            }
        }

        @Test func aLookRoundTripsThroughCodable() throws {
            let look = SoundPaletteLook(
                colors: SoundPalettePreset.candy.colors, hueShift: 30, saturation: 1.2, brightness: 0.9, cycle: 12)
            let data = try JSONEncoder().encode(look)
            #expect(try JSONDecoder().decode(SoundPaletteLook.self, from: data) == look)
        }

        /// A state fed 60 Hz frames, `seconds` of them from `start`, returning the next frame time.
        static func run(_ state: SoundVisualState, from start: Double, seconds: Double) -> Double {
            var now = start
            let frames = Int(seconds * 60)
            for i in 0..<frames {
                state.update(SoundVisualInput(frame: Script.frame(UInt64(i + 1), level: 0.5)), now: now)
                now += 1.0 / 60
            }
            return now
        }

        @Test func aChangedLookEasesInThroughALightnessPreservingMidpoint() {
            let state = SoundVisualState(seed: 3)
            var now = Self.run(state, from: 10, seconds: 1)
            let old = state.palette
            #expect(!state.isEasingLook)

            state.look = SoundPaletteLook(preset: .ocean)
            #expect(state.isEasingLook)
            now = Self.run(state, from: now, seconds: 0.3)  // about halfway through the 0.6 s ease
            let mid = state.palette
            #expect(state.isEasingLook)
            #expect(mid != old)

            now = Self.run(state, from: now, seconds: 1)
            #expect(!state.isEasingLook)
            let end = state.palette
            #expect(end != mid && end != old)

            // The midpoint sits between the old and the new color: closer to neither end, in lightness and distance.
            for (a, m, b) in [(old.c0, mid.c0, end.c0), (old.c1, mid.c1, end.c1), (old.c2, mid.c2, end.c2)] {
                let la = SoundPalette.oklab(a)
                let lm = SoundPalette.oklab(m)
                let lb = SoundPalette.oklab(b)
                #expect(lm.x >= min(la.x, lb.x) - 0.02 && lm.x <= max(la.x, lb.x) + 0.02)
                #expect(simd_length(lm - la) > 0.01, "the midpoint is still the old color")
            }
        }

        @Test func aPerceptualMixKeepsTheEndsAndTheMidpointStaysBright() {
            let red = SoundPalette(c0: SIMD3(1, 0, 0), c1: SIMD3(0, 1, 0), c2: SIMD3(0, 0, 1))
            let blue = SoundPalette(c0: SIMD3(0, 0, 1), c1: SIMD3(1, 0, 0), c2: SIMD3(0, 1, 0))
            let start = red.mixedPerceptually(with: blue, 0)
            #expect(simd_length(start.c0 - red.c0) < 0.01)
            let end = red.mixedPerceptually(with: blue, 1)
            #expect(simd_length(end.c0 - blue.c0) < 0.01)
            // A straight RGB mix of red and blue is a dark purple (0.5, 0, 0.5); the OKLab midpoint is lighter.
            let mid = red.mixedPerceptually(with: blue, 0.5).c0
            #expect(mid.x + mid.y + mid.z > 1.0)
        }

        @Test func theStageBackdropAndFringesFollowALookAndKeepTheirClassicColorsWhenNeutral() {
            let classic = SoundVisualizerStyle()
            #expect(classic.tinted(by: CanvasVisualizerTests.busyState()) == classic)
            let tinted = classic.tinted(by: CanvasVisualizerTests.busyState(look: SoundPaletteLook(preset: .toxic)))
            #expect(tinted.stage != classic.stage)
            #expect(tinted.phosphorStage != classic.phosphorStage)
            #expect(tinted.fringeA != classic.fringeA && tinted.fringeB != classic.fringeB)
            #expect(tinted.label == classic.label)
        }

        @Test(arguments: SoundVisualizerKind.allCases)
        func everyCanvasKindDrawsDifferentPixelsInANewPalette(_ kind: SoundVisualizerKind) throws {
            let base = try CanvasVisualizerTests.grid(kind, CanvasVisualizerTests.busyState())
            for (name, look) in Self.looks {
                let tinted = try CanvasVisualizerTests.grid(kind, CanvasVisualizerTests.busyState(look: look))
                #expect(base != tinted, "\(kind.rawValue) ignored the \(name) palette")
            }
        }

        @Test func everyPresetAndRandomRollKeepsFlashesRedSafe() {
            var looks = SoundPalettePreset.allCases.map { SoundPaletteLook(preset: $0) }
            looks += (0..<300).map { SoundPaletteLook.random(seed: UInt64($0)) }
            looks += [SoundPaletteLook(hueShift: -40, saturation: 2, brightness: 2)]
            for look in looks {
                let state = CanvasVisualizerTests.busyState(look: look)
                var limiter = IntenseFlashLimiter()
                let drive = IntenseDrive(
                    flashDemand: 1, glitchDemand: 1, tint: state.palette.c2, calm: false, now: 1, limiter: &limiter)
                let f = drive.flashColor
                #expect(f.x / (f.x + f.y + f.z) <= 0.61, "a red flash under \(look): \(f)")
                #expect(drive.flash <= IntenseFlashLimiter.maxLevel)
            }
        }
    }
#endif

#if canImport(Metal)
    import Metal

    extension IntenseVisualizerTests {
        @Test func theShaderIsToldWhenALookIsActive() {
            var drive = IntenseDrive()
            drive.flash = 0.1
            var uniforms = IntenseUniforms()
            let neutral = SoundVisualState(seed: 1)
            uniforms.fill(size: CGSize(width: 64, height: 64), state: neutral, drive: drive)
            #expect(uniforms.extra.y == 0)
            let tinted = SoundVisualState(seed: 1)
            tinted.look = SoundPaletteLook(preset: .candy)
            uniforms.fill(size: CGSize(width: 64, height: 64), state: tinted, drive: drive)
            #expect(uniforms.extra.y == 1)
        }

        @Test(.enabled(if: hasMetal, "no Metal device on this host"), arguments: IntenseKind.allCases)
        func everyIntenseKindDrawsDifferentPixelsInANewPalette(kind: IntenseKind) throws {
            let base = try Self.render(kind)
            for look in [SoundPaletteLook(preset: .ocean), SoundPaletteLook(hueShift: 120)] {
                #expect(try Self.render(kind, look: look) != base, "\(kind.rawValue) ignored \(look)")
            }
        }
    }
#endif
