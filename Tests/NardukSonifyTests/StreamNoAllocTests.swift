#if canImport(Darwin)
    import Darwin
    import Foundation
    import Synchronization
    import Testing

    @testable import NardukSonify

    /// A sample must cost no allocation, so the sonifier can run at motion or audio rates. This uses the same hook as
    /// NardukMusic's render-thread test (libmalloc's `malloc_logger`), counts every malloc made by this thread while
    /// armed, and feeds a running stream through `StreamSonifier.ingest`.
    ///
    /// Only an optimized build means anything here (a debug build calls unspecialized generics that box their
    /// values), so these tests run under `swift test -c release` and are skipped in debug.
    ///
    /// The `malloc_logger` slot is one process-wide pointer that NardukMusicDSPTests' `RenderThreadAllocationTests`
    /// also installs, and Swift Testing runs suites in parallel, so the two must never run in the same invocation:
    /// run this one alone, `swift test -c release --filter StreamNoAllocTests`. The name deliberately does not match
    /// the gate's `AllocationTests` filter, which runs the DSP suite.
    @Suite(.serialized) struct StreamNoAllocTests {
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
            let armed = StreamNoAllocTests.armedThread.load(ordering: .sequentiallyConsistent)
            guard armed != 0, armed == UInt(bitPattern: pthread_self()) else { return }
            let count = StreamNoAllocTests.allocations.add(1, ordering: .sequentiallyConsistent).newValue
            if count == 1 { StreamNoAllocTests.frameCount = backtrace(&StreamNoAllocTests.frames, 32) }
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
        @Test(.enabled(if: optimized, "allocation counts need an optimized build: swift test -c release"))
        func theHookSeesAnAllocation() throws {
            let count = try Self.countAllocations {
                let array = [Int](repeating: 7, count: 1_000)
                Self.escaped = UnsafeMutableRawPointer(bitPattern: array.count)
            }
            #expect(count >= 1)
        }

        /// A steady climb is the stream a sonifier hears for hours: its range keeps refreshing, the window keeps
        /// turning over, and after the first rise event nothing fires, so every sample is the quiet path.
        @Test(.enabled(if: optimized, "allocation counts need an optimized build: swift test -c release"))
        func aRunningStreamNeverAllocatesPerSample() throws {
            var sonifier = StreamSonifier(schema: StreamSchema(["price", "size", "flow"]), energy: "price")
            var values = [0.0, 1.0, 2.0]
            let rate = 100.0
            var i = 0
            func feed(_ count: Int) -> Int {
                var events = 0
                values.withUnsafeMutableBufferPointer { buffer in
                    for _ in 0..<count {
                        let t = Double(i) / rate
                        buffer[0] = 100 + 0.5 * t
                        buffer[1] = 1
                        buffer[2] = 2 + 0.01 * t
                        events += sonifier.ingest(time: t, values: UnsafeBufferPointer(buffer)).events.count
                        i += 1
                    }
                }
                return events
            }
            // First-touch work and the rise event happen before arming; the window (60 s) is already past full.
            let warmup = feed(Int(90 * rate))
            #expect(warmup > 0)
            var quiet = 0
            let count = try Self.countAllocations { quiet = feed(Int(30 * rate)) }
            #expect(quiet == 0, "the climb should be eventless once warm; it raised \(quiet) events")
            #expect(count == 0, "ingest allocated \(count) times, first at:\n\(Self.firstAllocationStack)")
        }
    }
#endif
