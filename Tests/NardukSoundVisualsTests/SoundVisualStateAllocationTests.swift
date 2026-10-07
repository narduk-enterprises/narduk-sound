#if canImport(Darwin)
    import Darwin
    import Foundation
    import NardukMusicCore
    import NardukSoundAnalysis
    import Synchronization
    import Testing

    @testable import NardukSoundVisuals

    /// `SoundVisualState.update` runs every display frame on the main thread; it must not allocate. Hooks libmalloc's
    /// `malloc_logger` (as `RenderThreadAllocationTests` does) and counts every allocation the arming thread makes
    /// while it drives a busy song through the state. Only an optimized build means anything: run it under
    /// `swift test -c release`; a debug build skips it.
    @Suite(.serialized) struct SoundVisualStateAllocationTests {
        #if DEBUG
            static let optimized = false
        #else
            static let optimized = true
        #endif

        typealias MallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

        static let armedThread = Atomic<UInt>(0)
        static let allocations = Atomic<Int>(0)

        static let logger: MallocLogger = { _, _, _, _, _, _ in
            let armed = SoundVisualStateAllocationTests.armedThread.load(ordering: .sequentiallyConsistent)
            guard armed != 0, armed == UInt(bitPattern: pthread_self()) else { return }
            let count = SoundVisualStateAllocationTests.allocations.add(1, ordering: .sequentiallyConsistent).newValue
            if count == 1 {
                SoundVisualStateAllocationTests.frameCount = backtrace(&SoundVisualStateAllocationTests.frames, 32)
            }
        }
        nonisolated(unsafe) static var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 32)
        nonisolated(unsafe) static var frameCount: Int32 = 0
        nonisolated(unsafe) static var sink: [Int] = []

        static var firstAllocationStack: String {
            (0..<Int(frameCount)).compactMap { index -> String? in
                var info = Dl_info()
                guard dladdr(frames[index], &info) != 0, let name = info.dli_sname else { return nil }
                return String(cString: name)
            }.joined(separator: "\n")
        }

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

        /// Proves the counter can fail in this build.
        @Test func theHookSeesAnAllocation() throws {
            let count = try Self.countAllocations {
                // Stored in a static, so the array really reaches the heap and cannot be optimized away.
                Self.sink = [Int](repeating: 7, count: 1_000)
            }
            #expect(count >= 1)
        }

        @Test(.enabled(if: optimized, "allocation counts need an optimized build: swift test -c release"))
        @MainActor func updatingABusySongNeverAllocates() throws {
            let state = SoundVisualState(seed: 7)
            // A tuned look (preset colors, hue, saturation, brightness, cycle) must not allocate either.
            state.look = SoundPaletteLook(
                colors: SoundPalettePreset.sunset.colors, hueShift: 30, saturation: 1.2, brightness: 0.9, cycle: 20)
            // Frames and contexts are built before arming: the caller owns them, the state only reads.
            let frames = (0..<8).map { Script.frame(UInt64($0 + 1), level: 0.2 + Float($0) * 0.1) }
            let sections = SongSection.allCases
            var contexts: [MusicContext] = []
            var notes = NoteCounters()
            for i in 0..<600 {
                var counts = HitCounters()
                if i % 6 == 0 { notes.record(48 + (i / 6) % 30) }
                let held = NoteSet([48 + (i / 6) % 30, 55 + (i / 9) % 20])
                for instrument in Instrument.allCases where (i + instrument.index) % 3 == 0 {
                    for _ in 0..<(i % 4 + 1) { counts.record(instrument) }
                }
                contexts.append(
                    MusicContext(
                        hitCounts: counts, step: i / 4, section: sections[(i / 60) % sections.count], energy: 0.9,
                        isRunning: true, heldNotes: held, noteCounts: notes))
            }
            var now = 1.0
            // Warm every path (first touch, particle pool wrap) before arming.
            for i in 0..<120 {
                state.update(SoundVisualInput(frame: frames[i % 8], music: contexts[i]), now: now)
                now += 1.0 / 60
            }
            let count = try Self.countAllocations {
                for i in 120..<600 {
                    let options = SoundVisualOptions(calm: i % 200 > 150, drive: i % 2 == 0 ? 0.9 : nil)
                    state.update(SoundVisualInput(frame: frames[i % 8], music: contexts[i]), now: now, options: options)
                    now += 1.0 / 60
                }
                for _ in 0..<60 {  // the no-music path
                    state.update(SoundVisualInput(frame: frames[0]), now: now)
                    now += 1.0 / 60
                }
            }
            #expect(count == 0, "update allocated \(count) times, first at:\n\(Self.firstAllocationStack)")
        }
    }
#endif
