import AVFoundation
import NardukMusicCore
import NardukMusicDSP
import Synchronization
import Testing

@testable import NardukMusicEngine

/// A synth pumped by a `ConductorDriver` the way the engine's pump thread does it (pump, then render a buffer), on the
/// calling thread: no audio device, no sound, and the same run every time.
final class PumpedSynth {
    let driver: ConductorDriver
    private(set) var core: DropSynthCore
    let frames: Int
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    /// Every note the driver wrote, on the synth's clock.
    private(set) var notes: [ScheduledNote] = []
    /// After each buffer: the samples rendered and the step position reached.
    private(set) var trace: [(samples: Int, position: Double)] = []
    var fingerprint: UInt64 = 0xCBF2_9CE4_8422_2325

    init(_ driver: ConductorDriver, frames: Int = 512) {
        self.driver = driver
        self.frames = frames
        core = DropSynthCore(sampleRate: 48_000, bpm: driver.startTempo)
        left = .allocate(capacity: frames)
        right = .allocate(capacity: frames)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    var seconds: Double { Double(core.renderedSampleCount) / core.sampleRate }

    /// One pump and one buffer.
    func step() {
        _ = driver.write(into: core) { note in
            core.schedule(note)
            notes.append(note)
        }
        core.render(frames: frames, left: left, right: right)
        trace.append((core.renderedSampleCount, core.renderedStepPosition))
        for index in 0..<frames {
            for sample in [left[index], right[index]] {
                fingerprint ^= UInt64(sample.bitPattern)
                fingerprint = fingerprint &* 0x0000_0100_0000_01B3
            }
        }
    }

    func run(seconds: Double, every: Double = .infinity, _ action: () -> Void = {}) {
        let end = self.seconds + seconds
        var mark = self.seconds + every
        while self.seconds < end {
            step()
            if self.seconds >= mark {
                action()
                mark += every
            }
        }
    }

    /// A new synth at the driver's tempo, as `DropEngine.start()` builds after a `stop()`.
    func replaceSynth() {
        core = DropSynthCore(sampleRate: 48_000, bpm: driver.startTempo)
    }

    /// The sample at which the clock reached `step` (interpolated within the buffer that crossed it).
    func sample(atStep step: Int) -> Double? {
        var previous = (samples: 0, position: 0.0)
        for point in trace {
            if point.position >= Double(step) {
                let fraction = (Double(step) - previous.position) / (point.position - previous.position)
                return Double(previous.samples) + fraction * Double(point.samples - previous.samples)
            }
            previous = point
        }
        return nil
    }
}

@Suite struct ConductorDriverTests {
    static func settings(_ genre: Genre = .house, seed: UInt64 = 0xC0FFEE) -> SongSettings {
        var settings = SongSettings(bpm: genre.defaultBPM, genre: genre)
        settings.seed = seed
        return settings
    }

    /// Samples in one bar at `bpm`.
    static func barSamples(_ bpm: Double) -> Double { 16 * 48_000 * 15 / bpm }

    @Test func itWritesEndlesslyAheadOfTheRenderPositionAndNeverDropsANote() {
        let synth = PumpedSynth(ConductorDriver(settings: Self.settings(), source: EnergyCurve.loop))
        var written = -1
        var skips = 0
        synth.run(seconds: 40, every: 9) {
            synth.driver.next()
            skips += 1
        }
        for point in synth.trace.indices.dropFirst() where synth.trace[point].position < synth.trace[point - 1].position
        {
            Issue.record("the clock went backwards at buffer \(point)")
        }
        let status = synth.driver.status
        written = status.written
        #expect(skips >= 4)
        #expect(Double(written) > synth.core.renderedStepPosition, "the cursor fell behind the render position")
        #expect(synth.core.droppedEvents == 0, "\(synth.core.droppedEvents) notes arrived too late")
        #expect(status.lastSwitch != nil)
        // Steps on the synth's clock rise with the song: none is written twice, none goes backwards.
        let steps = synth.notes.map(\.step)
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $0.0 <= $0.1 })
        #expect(steps.min() ?? -1 >= 0)
    }

    @Test func pausingWritesNothingMoreAndResumingCarriesOn() {
        let synth = PumpedSynth(ConductorDriver(settings: Self.settings(), source: EnergyCurve.swell))
        synth.run(seconds: 3)
        let before = synth.driver.status.written
        let notes = synth.notes.count
        // Paused: the render thread stops, so the position holds; the pump thread keeps waking (its backstop) and must
        // neither write past the look-ahead nor rewind.
        for _ in 0..<200 { synth.driver.pump(synth.core) }
        #expect(synth.driver.status.written == before)
        #expect(synth.notes.count == notes)
        synth.run(seconds: 3)
        let after = synth.driver.status
        #expect(after.written > before + 16, "resuming did not carry on (\(before) -> \(after.written))")
        #expect(synth.notes.dropFirst(notes).allSatisfy { $0.step > before - 1 }, "a step was written again")
        #expect(synth.core.droppedEvents == 0)
    }

    @Test func aNewSynthCarriesTheSongOnFromItsNextBarLine() {
        let driver = ConductorDriver(settings: Self.settings(), source: EnergyCurve.loop)
        let synth = PumpedSynth(driver)
        synth.run(seconds: 5)
        let written = driver.status.written
        let section = driver.status.snapshot.step
        synth.replaceSynth()
        synth.step()
        let origin = driver.origin
        #expect(origin > written && origin % 16 == 0, "origin \(origin) after step \(written)")
        #expect(origin - written <= 16)
        #expect(driver.status.snapshot.step > section)
        synth.run(seconds: 3)
        #expect(synth.core.droppedEvents == 0)
        // The song's step on the new synth is its own step plus the origin: the counter never went back to 0.
        #expect(Int(synth.core.renderedStepPosition) + origin > written)
    }

    @Test func nextLandsTheNewGenreAndItsTempoOnTheSwitchBar() throws {
        let driver = ConductorDriver(settings: Self.settings(.dubstep), source: EnergyCurve.loop)
        let synth = PumpedSynth(driver, frames: 128)
        synth.run(seconds: 4)
        let genre = try #require(driver.next())
        #expect(genre != .dubstep)
        #expect(driver.status.pendingGenre == genre)
        synth.run(seconds: 4)
        let change = try #require(driver.status.lastSwitch)
        #expect(change.genre == genre && change.bpm == genre.defaultBPM)
        #expect(change.step % 16 == 0)
        synth.run(seconds: 2 * Self.barSamples(genre.defaultBPM) / 48_000 + 0.5)

        // Within a buffer (the interpolation bends where the tempo changes inside one); the tempos differ by ~16 000.
        let barBefore = try #require(synth.sample(atStep: change.step)) - (synth.sample(atStep: change.step - 16) ?? 0)
        let switchBar = try #require(synth.sample(atStep: change.step + 16)) - (synth.sample(atStep: change.step) ?? 0)
        #expect(
            abs(barBefore - Self.barSamples(140)) < Double(synth.frames),
            "the bar before the switch ran \(barBefore) samples; switch \(change)")
        #expect(
            abs(switchBar - Self.barSamples(genre.defaultBPM)) < Double(synth.frames),
            "the switch bar ran \(switchBar) samples, not \(Self.barSamples(genre.defaultBPM)) at \(genre.defaultBPM)")

        let status = driver.status
        #expect(status.genre == genre && status.bpm == genre.defaultBPM && status.pendingGenre == nil)
        #expect(status.heard(atStep: change.step - 1) == (.dubstep, 140))
        #expect(status.heard(atStep: change.step) == (genre, genre.defaultBPM))
        #expect(driver.withConductor { $0.activeGenre } == genre)
    }

    @Test func nextAlwaysChoosesADifferentGenreAndTheSameSeedSkipsTheSameWay() {
        func skips(seed: UInt64) -> [Genre] {
            let driver = ConductorDriver(settings: Self.settings(seed: seed))
            let synth = PumpedSynth(driver)
            var picks: [Genre] = []
            for _ in 0..<6 {
                let playing = driver.withConductor { $0.activeGenre }
                guard let pick = driver.next() else { return picks }
                #expect(pick != playing)
                picks.append(pick)
                synth.run(seconds: 3)
                #expect(driver.withConductor { $0.activeGenre } == pick)
            }
            return picks
        }
        let first = skips(seed: 1)
        #expect(first.count == 6)
        #expect(skips(seed: 1) == first)
        #expect(skips(seed: 2) != first)
    }

    @Test func theSameSeedWritesTheSameNotesAndSamples() {
        func render(seed: UInt64) -> (notes: [ScheduledNote], fingerprint: UInt64) {
            let driver = ConductorDriver(settings: Self.settings(.dubstep, seed: seed), source: EnergyCurve.loop)
            let synth = PumpedSynth(driver)
            synth.run(seconds: 8, every: 5) { driver.next() }
            return (synth.notes, synth.fingerprint)
        }
        let first = render(seed: 7)
        #expect(!first.notes.isEmpty)
        let again = render(seed: 7)
        #expect(again.notes == first.notes)
        #expect(again.fingerprint == first.fingerprint)
        #expect(render(seed: 8).notes != first.notes)
    }

    @Test func ingestedSignalsReachTheConductorBeforeTheNextWrite() {
        let quiet = ConductorDriver(settings: Self.settings())
        let loud = ConductorDriver(settings: Self.settings())
        let a = PumpedSynth(quiet)
        let b = PumpedSynth(loud)
        for _ in 0..<40 {
            quiet.ingest(MusicSignal(level: 0.05))
            loud.ingest(MusicSignal(level: 0.95))
            a.run(seconds: 0.25)
            b.run(seconds: 0.25)
        }
        #expect(loud.status.snapshot.energy > quiet.status.snapshot.energy + 0.3)
    }

    @Test func theDemoPartPlaysDemoPatternAndHasNoGenreToSkip() {
        let driver = ConductorDriver.demo()
        let synth = PumpedSynth(driver)
        synth.run(seconds: 2)
        let written = driver.status.written
        #expect(synth.notes == DemoPattern.notes(in: 0...written))
        #expect(driver.next() == nil)
        #expect(driver.status.section == DemoPattern.section(atStep: written))
    }

    @Test func aTempoSetFromOutsideLandsOnTheNextBarLine() throws {
        let driver = ConductorDriver(settings: Self.settings(.house))
        let synth = PumpedSynth(driver, frames: 128)
        synth.run(seconds: 1)
        let position = synth.core.renderedStepPosition
        driver.setTempo(150)
        synth.run(seconds: 4)
        let bar = (Int(position) / 16 + 1) * 16
        let next = try #require(synth.sample(atStep: bar + 16)) - (synth.sample(atStep: bar) ?? 0)
        #expect(
            abs(next - Self.barSamples(150)) < Double(synth.frames),
            "the bar after the request ran \(next) samples, bar \(bar), \(Self.barSamples(150))")
        #expect(driver.status.bpm == 150)
    }
}

/// The live arrangement without an audio device: a stand-in render thread calls the engine's render block in real
/// time, and the pump thread writes from its signals alone. Nothing here touches the main thread.
@Suite struct LivePumpTests {
    @Test func thePumpThreadFollowsTheRenderThreadAndKeepsItFed() async throws {
        let driver = ConductorDriver(settings: ConductorDriverTests.settings(.dubstep), source: EnergyCurve.loop)
        let core = DropSynthCore(sampleRate: 48_000, bpm: driver.startTempo)
        let wake = PumpWake()
        let feed = NoteFeed()
        feed.pump(driver, into: core)  // the engine primes the first look-ahead before the first buffer
        let pump = LivePump(wake: wake) { feed.pump(driver, into: core) }
        defer { pump.cancel() }
        let block = DropEngine.makeRenderBlock(core, wake: wake)
        let frames = 512
        let behind = Atomic<Int>(0)

        let render = Thread {
            let buffers = AudioBufferList.allocate(maximumBuffers: 2)
            let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            let bytes = UInt32(frames * MemoryLayout<Float>.size)
            buffers[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(left))
            buffers[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(right))
            var silence = ObjCBool(false)
            var time = AudioTimeStamp()
            // 1.5 s of buffers at real-time pace.
            for _ in 0..<(48_000 * 3 / 2 / frames) {
                _ = block(&silence, &time, AVAudioFrameCount(frames), buffers.unsafeMutablePointer)
                usleep(UInt32(Double(frames) / 48_000 * 1_000_000))
                if driver.status.written < Int(core.renderedStepPosition) { behind.add(1, ordering: .relaxed) }
            }
            left.deallocate()
            right.deallocate()
            free(buffers.unsafeMutablePointer)
        }
        render.start()
        while !render.isFinished { try await Task.sleep(for: .milliseconds(20)) }

        #expect(core.renderedSampleCount > 48_000)
        #expect(Double(driver.status.written) > core.renderedStepPosition)
        #expect(behind.load(ordering: .relaxed) == 0, "the cursor fell behind \(behind.load(ordering: .relaxed)) times")
        #expect(core.droppedEvents == 0, "\(core.droppedEvents) notes arrived too late")
    }
}

/// `DropEngine` with a driver, rendered offline (manual rendering: no device, no sound, no real-time clock).
@MainActor @Suite struct ConductorDriverEngineTests {
    static func engine() -> DropEngine {
        let engine = DropEngine()
        engine.offlineFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)
        engine.mutesHardwareOutput = true
        return engine
    }

    @Test func pauseAndResumeKeepTheStepAndTheSong() throws {
        let engine = Self.engine()
        let driver = ConductorDriver(settings: ConductorDriverTests.settings(), source: EnergyCurve.swell)
        try engine.play(driver)
        defer { engine.stop() }
        _ = try engine.renderOffline(frames: 96_000)
        let step = engine.currentStep
        let written = driver.status.written
        #expect(step > 8)
        engine.pause()
        #expect(engine.isPaused && engine.isRunning)
        try engine.play(driver)  // resumes
        #expect(!engine.isPaused)
        _ = try engine.renderOffline(frames: 96_000)
        #expect(engine.currentStep > step, "the step went from \(step) to \(engine.currentStep)")
        #expect(driver.status.written > written)
        #expect(engine.latestMusic.step == engine.currentStep)
    }

    @Test func stopAndStartCarryTheStepOnInsteadOfRestartingTheSong() throws {
        let engine = Self.engine()
        let driver = ConductorDriver(settings: ConductorDriverTests.settings(), source: EnergyCurve.loop)
        try engine.play(driver)
        _ = try engine.renderOffline(frames: 96_000)
        let step = engine.currentStep
        engine.stop()
        try engine.start()
        defer { engine.stop() }
        _ = try engine.renderOffline(frames: 48_000)
        #expect(engine.currentStep > step, "the step went from \(step) back to \(engine.currentStep)")
        #expect(driver.origin > 0)
    }

    @Test func theEngineEchoesTheGenreAndTempoTheListenerHears() throws {
        let engine = Self.engine()
        let driver = ConductorDriver(settings: ConductorDriverTests.settings(.dubstep), source: EnergyCurve.loop)
        try engine.play(driver)
        defer { engine.stop() }
        _ = try engine.renderOffline(frames: 48_000)
        #expect(engine.settings.genre == .dubstep && engine.settings.bpm == 140)
        driver.setGenre(.drumAndBass)
        _ = try engine.renderOffline(frames: 48_000 * 5)
        let change = try #require(driver.status.lastSwitch)
        #expect(engine.currentStep >= change.step)
        #expect(engine.settings.genre == .drumAndBass && engine.settings.bpm == 174)
        #expect(engine.section == driver.status.section)
    }

    @Test func theDemoPlaysThroughADriver() throws {
        let engine = Self.engine()
        try engine.playDemo()
        defer { engine.stop() }
        _ = try engine.renderOffline(frames: 48_000)
        #expect(engine.driver != nil)
        #expect((engine.driver?.status.written ?? -1) > 0)
    }
}

#if canImport(Darwin)
    /// The driver adds work to the render thread's path (a semaphore signal after each buffer) and wakes a pump thread
    /// that, between steps, has nothing to write. Neither may allocate. Needs an optimized build: `swift test -c
    /// release`, as the gate runs it.
    @Suite(.serialized) struct ConductorDriverAllocationTests {
        #if DEBUG
            static let optimized = false
        #else
            static let optimized = true
        #endif

        typealias MallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
        static let armedThread = Atomic<UInt>(0)
        static let allocations = Atomic<Int>(0)
        static let logger: MallocLogger = { _, _, _, _, _, _ in
            let armed = ConductorDriverAllocationTests.armedThread.load(ordering: .sequentiallyConsistent)
            guard armed != 0, armed == UInt(bitPattern: pthread_self()) else { return }
            ConductorDriverAllocationTests.allocations.add(1, ordering: .sequentiallyConsistent)
        }
        nonisolated(unsafe) static var escaped: UnsafeMutableRawPointer?

        /// Counts allocations `body` makes on this thread (libmalloc's `malloc_logger` hook).
        static func countAllocations(_ body: () -> Void) throws -> Int {
            let handle = dlopen(nil, RTLD_NOW)
            defer { dlclose(handle) }
            let symbol = try #require(dlsym(handle, "malloc_logger"), "libmalloc exports no malloc_logger")
            let slot = symbol.assumingMemoryBound(to: Optional<MallocLogger>.self)
            let previous = slot.pointee
            allocations.store(0, ordering: .sequentiallyConsistent)
            slot.pointee = logger
            armedThread.store(UInt(bitPattern: pthread_self()), ordering: .sequentiallyConsistent)
            body()
            armedThread.store(0, ordering: .sequentiallyConsistent)
            slot.pointee = previous
            return allocations.load(ordering: .sequentiallyConsistent)
        }

        @Test func theHookSeesAnAllocation() throws {
            let count = try Self.countAllocations {
                let array = [Int](repeating: 7, count: 1_000)
                Self.escaped = UnsafeMutableRawPointer(bitPattern: array.count)
            }
            #expect(count >= 1)
        }

        @Test(.enabled(if: optimized, "allocation counts need an optimized build: swift test -c release"))
        func theRenderBlockAndAnIdlePumpNeverAllocate() throws {
            let driver = ConductorDriver(settings: ConductorDriverTests.settings(.dubstep), source: EnergyCurve.loop)
            let core = DropSynthCore(sampleRate: 48_000, bpm: driver.startTempo)
            let wake = PumpWake()
            let feed = NoteFeed()
            let block = DropEngine.makeRenderBlock(core, wake: wake)
            let frames = 512
            let buffers = AudioBufferList.allocate(maximumBuffers: 2)
            let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            defer {
                left.deallocate()
                right.deallocate()
                free(buffers.unsafeMutablePointer)
            }
            let bytes = UInt32(frames * MemoryLayout<Float>.size)
            buffers[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(left))
            buffers[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(right))
            var silence = ObjCBool(false)
            var time = AudioTimeStamp()

            var renderAllocations = 0
            var idleAllocations = 0
            for _ in 0..<400 {
                feed.pump(driver, into: core)  // writing a step allocates (the conductor), off the render thread
                idleAllocations += try Self.countAllocations {
                    feed.pump(driver, into: core)  // nothing new is due: the common wake
                    driver.pump(core)
                }
                renderAllocations += try Self.countAllocations {
                    _ = block(&silence, &time, AVAudioFrameCount(frames), buffers.unsafeMutablePointer)
                }
            }
            #expect(core.renderedSampleCount == 400 * frames)
            #expect(renderAllocations == 0, "the render block allocated \(renderAllocations) times")
            #expect(idleAllocations == 0, "an idle pump allocated \(idleAllocations) times")
        }
    }
#endif
