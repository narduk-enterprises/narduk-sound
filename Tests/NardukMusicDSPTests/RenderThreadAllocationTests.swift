#if canImport(Darwin)
    import Darwin
    import Foundation
    import NardukMusicCore
    import Synchronization
    import Testing

    @testable import NardukMusicDSP

    /// The render thread must never allocate: a malloc there can take a lock and miss the audio deadline. This hooks
    /// libmalloc's `malloc_logger` (the hook MallocStackLogging uses), counts every malloc, realloc and free made by
    /// the rendering thread while armed, and renders a busy song through `DropSynthCore.render`.
    ///
    /// Only an optimized build means anything here: a debug build calls unspecialized generics that box their
    /// values, so the render test runs under `swift test -c release` (as CI does) and is skipped in debug.
    @Suite(.serialized) struct RenderThreadAllocationTests {
        #if DEBUG
            static let optimized = false
        #else
            static let optimized = true
        #endif

        typealias MallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

        // Atomics, not plain statics: the optimizer knows malloc touches no Swift memory, so it would fold a plain
        // counter read after a malloc to its value before it (and the test would pass while measuring nothing).
        static let armedThread = Atomic<UInt>(0)
        static let allocations = Atomic<Int>(0)

        static let logger: MallocLogger = { _, _, _, _, _, _ in
            let armed = RenderThreadAllocationTests.armedThread.load(ordering: .sequentiallyConsistent)
            guard armed != 0, armed == UInt(bitPattern: pthread_self()) else { return }
            let count = RenderThreadAllocationTests.allocations.add(1, ordering: .sequentiallyConsistent).newValue
            if count == 1 {
                RenderThreadAllocationTests.frameCount = backtrace(&RenderThreadAllocationTests.frames, 32)
            }
        }
        /// The call stack of the first counted allocation, to name the culprit in a failure.
        nonisolated(unsafe) static var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 32)
        nonisolated(unsafe) static var frameCount: Int32 = 0
        nonisolated(unsafe) static var escaped: UnsafeMutableRawPointer?

        static var firstAllocationStack: String {
            (0..<Int(frameCount)).compactMap { index -> String? in
                var info = Dl_info()
                guard dladdr(frames[index], &info) != 0, let name = info.dli_sname else { return nil }
                return String(cString: name)
            }.joined(separator: "\n")
        }

        /// Counts allocations `body` makes on this thread.
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

        /// Proves the counter can fail in this build: an escaping array is a real heap allocation even when
        /// optimized (a bare malloc/free pair is not; the optimizer deletes it).
        @Test func theHookSeesAnAllocation() throws {
            let count = try Self.countAllocations {
                let array = [Int](repeating: 7, count: 1_000)
                Self.escaped = UnsafeMutableRawPointer(bitPattern: array.count)
            }
            #expect(count >= 1)
        }

        @Test(.enabled(if: optimized, "allocation counts need an optimized build: swift test -c release"))
        func renderingABusySongNeverAllocates() throws {
            let sampleRate = 48_000.0
            let core = DropSynthCore(sampleRate: sampleRate, bpm: 140)
            let frames = 512
            let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            defer {
                left.deallocate()
                right.deallocate()
            }
            // Every instrument, many voices, a tempo change: the paths the render thread takes in a real set.
            for note in DemoPattern.notes(in: 0...(16 * 8 - 1)) { core.schedule(note) }
            for step in stride(from: 0, to: 128, by: 3) {
                for instrument in Instrument.allCases {
                    core.schedule(
                        ScheduledNote(
                            step: step, instrument: instrument, velocity: 0.8,
                            params: NoteParams(
                                pitch: 41 + step % 24, lengthSteps: 2, wobbleRate: .eighth, formant: 0.5,
                                drive: 0.6, voice: step, pan: 0.3, glide: 0.5, delay: 0.1)))
                }
            }
            core.render(frames: frames, left: left, right: right)  // first-touch work happens before arming
            core.setTempo(150)
            let count = try Self.countAllocations {
                for _ in 0..<1_000 { core.render(frames: frames, left: left, right: right) }
            }
            #expect(count == 0, "the render thread allocated \(count) times, first at:\n\(Self.firstAllocationStack)")
        }

        /// The guitars: strings from a pooled voice, a strum expanded into six, voice stealing past 24 strings, and
        /// a tempo change, none of it allocating.
        @Test(.enabled(if: optimized, "allocation counts need an optimized build: swift test -c release"))
        func playingTheGuitarsNeverAllocates() throws {
            let core = DropSynthCore(sampleRate: 48_000, bpm: 120)
            let frames = 512
            let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            defer {
                left.deallocate()
                right.deallocate()
            }
            let guitars: [Instrument] = [.acousticGuitar, .electricGuitar, .bassGuitar, .strum, .electricStrum]
            for step in 0..<128 {
                for (index, instrument) in guitars.enumerated() where (step + index) % 2 == 0 {
                    core.schedule(
                        ScheduledNote(
                            step: step, instrument: instrument, velocity: 0.4 + 0.6 * Double(step % 5) / 4,
                            params: NoteParams(
                                pitch: 28 + (step * 3 + index) % 50, lengthSteps: 1 + step % 9,
                                formant: Double(step % 2),
                                drive: Double(step % 4) / 3, voice: step, pan: Double(index) / 2 - 1, delay: 0.25)))
                }
            }
            core.render(frames: frames, left: left, right: right)  // first-touch work happens before arming
            core.setTempo(100)
            let count = try Self.countAllocations {
                for _ in 0..<1_000 { core.render(frames: frames, left: left, right: right) }
            }
            #expect(count == 0, "the render thread allocated \(count) times, first at:\n\(Self.firstAllocationStack)")
            #expect(core.takeHits().isSuperset(of: Set(guitars)))
        }
    }
#endif
