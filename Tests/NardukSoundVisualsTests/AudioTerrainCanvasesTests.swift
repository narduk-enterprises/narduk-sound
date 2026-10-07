#if canImport(SwiftUI) && canImport(AppKit)
    import NardukMusicCore
    import NardukSoundAnalysis
    import SwiftUI
    import Testing

    @testable import NardukSoundVisuals

    /// Geometry, reactivity and calm behavior of the audio-terrain canvas. The golden grid lives with the other
    /// canvas kinds; this file checks the pure helpers and that bass, highs and the kick move different parts of
    /// the picture.
    @MainActor @Suite struct AudioTerrainCanvasesTests {
        static let card = CGSize(width: 480, height: 270)

        static func flatWave(_ level: Float) -> [Float] {
            [Float](repeating: level, count: SoundFrame.waveformCount)
        }

        static func bands(_ fill: (Int) -> Float) -> [Float] {
            (0..<SoundFrame.spectrumCount).map(fill)
        }

        static func terrainState(
            spectrum: [Float], waveform: [Float], section: SongSection = .build, energy: Float = 0.55,
            kicks: UInt32 = 0, calm: Bool = false
        ) -> SoundVisualState {
            let state = SoundVisualState(seed: 7)
            var now = 20.0
            var counts = HitCounters()
            for frameIndex in 0..<48 {
                let frame = SoundFrame(
                    sequence: UInt64(frameIndex + 1), time: Double(frameIndex) / 60, spectrum: spectrum,
                    waveform: waveform, peakDB: -8, rmsDB: -14)
                if frameIndex == 47 {
                    for _ in 0..<kicks { counts.record(.kick) }
                }
                let music = MusicContext(
                    hitCounts: counts, step: 8 + frameIndex / 8, section: section, energy: energy, isRunning: true)
                state.update(
                    SoundVisualInput(frame: frame, music: music), now: now, options: SoundVisualOptions(calm: calm))
                now += 1.0 / 60
            }
            return state
        }

        static func slice(_ grid: [Int], rows: Range<Int>, columns: Range<Int>) -> [Int] {
            let width = CanvasVisualizerTests.columns
            var out: [Int] = []
            for row in rows {
                for column in columns { out.append(grid[row * width + column]) }
            }
            return out
        }

        static func point(
            column: Int, bass: Float = 0, mids: Float = 0, highs: Float = 0, lift: Float = 0, wave: Float = 0.7
        ) -> CGPoint? {
            flatWave(wave).withUnsafeBufferPointer { history in
                SoundVisualizers.terrainRidgePoint(
                    age: 0, count: 1, column: column, columns: SoundVisualizers.terrainColumns, scroll: 0.25,
                    bass: bass, mids: mids, highs: highs, lift: lift, history: history, head: 0, size: card)
            }
        }

        @Test func theNearGroundStaysInsideTheCard() {
            let left = SoundVisualizers.terrainProject(
                x: -SoundVisualizers.terrainHalfWidth, height: 0, z: SoundVisualizers.terrainNear, size: Self.card)
            let right = SoundVisualizers.terrainProject(
                x: SoundVisualizers.terrainHalfWidth, height: 0, z: SoundVisualizers.terrainNear, size: Self.card)
            let horizon = SoundVisualizers.terrainHorizon(Self.card.height)
            #expect(left != nil && right != nil)
            #expect(left!.x > 8 && right!.x < Self.card.width - 8)
            #expect(left!.y > horizon && left!.y < Self.card.height - 8)
            #expect(abs(left!.y - right!.y) < 0.5)
        }

        @Test func projectionPutsDistanceOnTheHorizonAndHeightUpward() {
            let near = SoundVisualizers.terrainProject(
                x: 0, height: 0, z: SoundVisualizers.terrainNear, size: Self.card)
            let far = SoundVisualizers.terrainProject(
                x: 0, height: 0, z: SoundVisualizers.terrainFar, size: Self.card)
            let raised = SoundVisualizers.terrainProject(x: 0, height: 1, z: 2, size: Self.card)
            let flat = SoundVisualizers.terrainProject(x: 0, height: 0, z: 2, size: Self.card)
            let right = SoundVisualizers.terrainProject(x: 0.5, height: 0, z: 2, size: Self.card)
            #expect(far!.y < near!.y)
            #expect(far!.y > SoundVisualizers.terrainHorizon(Self.card.height))
            #expect(raised!.y < flat!.y)
            #expect(right!.x > Self.card.width / 2)
            #expect(
                SoundVisualizers.terrainProject(x: 0, height: 0, z: SoundVisualizers.terrainMinZ, size: Self.card)
                    == nil)
            #expect(SoundVisualizers.terrainProject(x: 0, height: 0, z: 0, size: Self.card) == nil)
        }

        @Test func rowsRecedeAndScrollTowardTheCamera() {
            let front = SoundVisualizers.terrainDepth(index: 0, count: 10, scroll: 0.2)
            let back = SoundVisualizers.terrainDepth(index: 7, count: 10, scroll: 0.2)
            let before = SoundVisualizers.terrainDepth(index: 3, count: 8, scroll: 0.1)
            let after = SoundVisualizers.terrainDepth(index: 3, count: 8, scroll: 0.75)
            #expect(front < back)
            #expect(after < before)
            for scroll in [0.0, 0.5, 3.2, -1.3] {
                let depth = SoundVisualizers.terrainDepth(index: 2, count: 8, scroll: scroll)
                #expect(depth >= SoundVisualizers.terrainNear - 0.001)
                #expect(depth <= SoundVisualizers.terrainFar + 0.001)
            }
        }

        @Test func calmScrollsAtPointFourAndADropSpeedsTheRoll() {
            let full = SoundVisualizers.terrainScroll(travel: 10, drop: 0, calm: false)
            let calm = SoundVisualizers.terrainScroll(travel: 10, drop: 0, calm: true)
            let dropped = SoundVisualizers.terrainScroll(travel: 10, drop: 1, calm: false)
            #expect(abs(calm - full * 0.4) < 1e-9)
            #expect(dropped > full * 2)
            #expect(SoundVisualizers.terrainMotion(calm: true) == 0.4)
        }

        @Test func bassLiftsTheCenterMidsTheShouldersAndHighsTheEdges() {
            let centerBass = SoundVisualizers.terrainHeight(
                u: 0, bass: 1, mids: 0, highs: 0, wave: 0, jitter: 0, lift: 0)
            let edgeBass = SoundVisualizers.terrainHeight(
                u: 1, bass: 1, mids: 0, highs: 0, wave: 0, jitter: 0, lift: 0)
            #expect(centerBass > edgeBass + 0.4)

            let shoulder = SoundVisualizers.terrainHeight(
                u: 0.5, bass: 0, mids: 1, highs: 0, wave: 0, jitter: 0, lift: 0)
            let middle = SoundVisualizers.terrainHeight(
                u: 0, bass: 0, mids: 1, highs: 0, wave: 0, jitter: 0, lift: 0)
            #expect(shoulder > middle + 0.2)

            let edgeHigh = SoundVisualizers.terrainHeight(
                u: 1, bass: 0, mids: 0, highs: 1, wave: 0, jitter: 1, lift: 0)
            let centerHigh = SoundVisualizers.terrainHeight(
                u: 0, bass: 0, mids: 0, highs: 1, wave: 0, jitter: 1, lift: 0)
            #expect(edgeHigh > centerHigh + 0.3)

            let lifted = SoundVisualizers.terrainHeight(
                u: 0, bass: 0.4, mids: 0, highs: 0, wave: 0.4, jitter: 0, lift: 1)
            let resting = SoundVisualizers.terrainHeight(
                u: 0, bass: 0.4, mids: 0, highs: 0, wave: 0.4, jitter: 0, lift: 0)
            #expect(lifted > resting + 0.3)
            #expect(
                SoundVisualizers.terrainHeight(u: 0.2, bass: 0, mids: 0, highs: 0, wave: 1, jitter: 0, lift: 0)
                    > SoundVisualizers.terrainHeight(u: 0.2, bass: 0, mids: 0, highs: 0, wave: -1, jitter: 0, lift: 0))
        }

        @Test func aPlacedRidgePutsBassInTheMiddleAndTheBeatAboveTheRestingLine() {
            let columns = SoundVisualizers.terrainColumns
            let center = Self.point(column: columns / 2, bass: 1)
            let edge = Self.point(column: 0, bass: 1)
            #expect(center!.y + 8 < edge!.y)
            let lifted = Self.point(column: columns / 2, bass: 0.6, lift: 1)
            let resting = Self.point(column: columns / 2, bass: 0.6, lift: 0)
            #expect(lifted!.y < resting!.y)
            let highEdge = Self.point(column: 0, highs: 1, wave: 0.2)
            let highCenter = Self.point(column: columns / 2, highs: 1, wave: 0.2)
            #expect(highEdge!.y < highCenter!.y)
        }

        @Test func historyAgeZeroIsTheNewestSlot() {
            #expect(SoundVisualizers.terrainHistorySlot(age: 0, head: 4, depth: 10) == 4)
            #expect(SoundVisualizers.terrainHistorySlot(age: 2, head: 4, depth: 10) == 2)
            #expect(SoundVisualizers.terrainHistorySlot(age: 1, head: 0, depth: 10) == 9)
            var samples = [Float](repeating: 0, count: SoundFrame.waveformCount)
            samples.replaceSubrange(128..<256, with: [Float](repeating: 1, count: 128))
            let read = samples.withUnsafeBufferPointer { buffer in
                SoundVisualizers.terrainWaveSample(
                    buffer, base: 0, sampleCount: SoundFrame.waveformCount, column: 1, columns: 4)
            }
            #expect(read == 1)
            let spectrum = Self.bands { $0 < 10 ? 1 : 0 }
            let energy = spectrum.withUnsafeBufferPointer { buffer in
                (
                    SoundVisualizers.terrainBandEnergy(buffer, from: 0, to: 10),
                    SoundVisualizers.terrainBandEnergy(buffer, from: 36, to: 64)
                )
            }
            #expect(energy.0 == 1)
            #expect(energy.1 == 0)
            #expect(SoundVisualizers.terrainU(column: 0, columns: 11) == -1)
            #expect(SoundVisualizers.terrainU(column: 10, columns: 11) == 1)
            let hash = SoundVisualizers.terrainHash(3)
            #expect(hash == SoundVisualizers.terrainHash(3))
            #expect(hash != SoundVisualizers.terrainHash(4))
            #expect(hash >= 0 && hash <= 1)
        }

        @Test func theSunKeepsItsUpperBandsAndOpensTheLowerOnes() {
            #expect(SoundVisualizers.terrainSunBandIncluded(0, count: 8))
            #expect(SoundVisualizers.terrainSunBandIncluded(3, count: 8))
            #expect(SoundVisualizers.terrainSunBandIncluded(6, count: 8))
            #expect(!SoundVisualizers.terrainSunBandIncluded(5, count: 8))
            #expect(!SoundVisualizers.terrainSunBandIncluded(7, count: 8))
            #expect(!SoundVisualizers.terrainSunBandIncluded(-1, count: 8))
            #expect(!SoundVisualizers.terrainSunBandIncluded(8, count: 8))
        }

        @Test func bassAndHighsMoveDifferentPartsOfThePicture() throws {
            let wave = Self.flatWave(0.55)
            let bass = Self.bands { $0 < 10 ? 1 : 0 }
            let highs = Self.bands { $0 >= 36 ? 1 : 0 }
            let bassGrid = try CanvasVisualizerTests.grid(
                .audioTerrain, Self.terrainState(spectrum: bass, waveform: wave))
            let highGrid = try CanvasVisualizerTests.grid(
                .audioTerrain, Self.terrainState(spectrum: highs, waveform: wave))
            let center = CanvasVisualizerTests.drift(
                Self.slice(bassGrid, rows: 3..<7, columns: 5..<11),
                Self.slice(highGrid, rows: 3..<7, columns: 5..<11))
            let edge = CanvasVisualizerTests.drift(
                Self.slice(bassGrid, rows: 4..<8, columns: 0..<3), Self.slice(highGrid, rows: 4..<8, columns: 0..<3))
            #expect(center > 1, "bass should move the central ridges, drift \(center)")
            #expect(edge > 1, "highs should move the edges, drift \(edge)")
        }

        @Test func aKickLiftsTheNearestRidge() throws {
            let wave = Self.flatWave(0.6)
            let spectrum = Self.bands { index in index < 16 ? Float(0.85) : Float(0.15) }
            let kicked = try CanvasVisualizerTests.grid(
                .audioTerrain, Self.terrainState(spectrum: spectrum, waveform: wave, kicks: 1))
            let quiet = try CanvasVisualizerTests.grid(
                .audioTerrain, Self.terrainState(spectrum: spectrum, waveform: wave, kicks: 0))
            let drift = CanvasVisualizerTests.drift(
                Self.slice(kicked, rows: 4..<8, columns: 4..<12), Self.slice(quiet, rows: 4..<8, columns: 4..<12))
            #expect(drift > 1, "the kick should lift the near ridge, drift \(drift)")
        }

        @Test func theSameStateDrawsTheSamePicture() throws {
            let state = CanvasVisualizerTests.busyState()
            let first = try CanvasVisualizerTests.grid(.audioTerrain, state)
            let second = try CanvasVisualizerTests.grid(.audioTerrain, state)
            #expect(CanvasVisualizerTests.drift(first, second) == 0)
        }

        @Test func calmStillDrawsAndDoesNotFlash() throws {
            let wave = Self.flatWave(0.45)
            let spectrum = Self.bands { _ in 0.4 }
            let state = Self.terrainState(spectrum: spectrum, waveform: wave, section: .drop, kicks: 4, calm: true)
            #expect(state.calm)
            #expect(state.flash == 0)
            let grid = try CanvasVisualizerTests.grid(.audioTerrain, state)
            #expect(grid.count == CanvasVisualizerTests.columns * CanvasVisualizerTests.rows)
            #expect((grid.max() ?? 0) > 12)
            let again = try CanvasVisualizerTests.grid(.audioTerrain, state)
            #expect(CanvasVisualizerTests.drift(grid, again) == 0)
        }
    }

    @MainActor @Suite(.serialized) struct AudioTerrainAllocationTests {
        @Test(.enabled(if: SoundVisualStateAllocationTests.optimized, "allocation counts need swift test -c release"))
        func terrainHelpersNeverAllocate() throws {
            let state = CanvasVisualizerTests.busyState()
            let size = CGSize(width: 480, height: 270)
            var sink: Float = 0
            let count = try SoundVisualStateAllocationTests.countAllocations {
                for _ in 0..<2_000 {
                    let bass = SoundVisualizers.terrainBandEnergy(state.spectrum, from: 0, to: 10)
                    let mids = SoundVisualizers.terrainBandEnergy(state.spectrum, from: 10, to: 36)
                    let highs = SoundVisualizers.terrainBandEnergy(state.spectrum, from: 36, to: 64)
                    let scroll = SoundVisualizers.terrainScroll(
                        travel: state.travel, drop: state.dropAmount, calm: state.calm)
                    sink += bass + mids + highs + Float(scroll)
                    let columns = SoundVisualizers.terrainColumns
                    for age in 0..<state.historyCount {
                        for column in stride(from: 0, to: columns, by: 3) {
                            guard
                                let point = SoundVisualizers.terrainRidgePoint(
                                    age: age, count: state.historyCount, column: column, columns: columns,
                                    scroll: scroll, bass: bass, mids: mids, highs: highs, lift: state.kick,
                                    history: state.history, head: state.historyHead, size: size)
                            else { continue }
                            sink += Float(point.x + point.y)
                        }
                    }
                }
            }
            #expect(count == 0, "allocated \(count): \(SoundVisualStateAllocationTests.firstAllocationStack)")
            #expect(sink.isFinite)
        }
    }
#endif
