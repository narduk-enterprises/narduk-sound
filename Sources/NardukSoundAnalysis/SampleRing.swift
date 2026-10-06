import Synchronization

/// A lock-free single-writer / single-reader ring that always holds the most recent samples. The writer (an audio
/// tap or render thread) overwrites the oldest data and never blocks, allocates or touches a reference count; the
/// reader (the analysis clock) copies the latest window and learns whether the writer lapped it mid-copy.
public final class SampleRing: @unchecked Sendable {
    public let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>
    /// Total samples ever written (owned by the writer).
    private let head = Atomic<Int>(0)

    /// `capacity` is rounded up to a power of two (at least 2).
    public init(capacity: Int) {
        var size = 2
        while size < capacity { size <<= 1 }
        self.capacity = size
        mask = size - 1
        storage = .allocate(capacity: size)
        storage.initialize(repeating: 0, count: size)
    }

    deinit {
        storage.deallocate()
    }

    /// Total samples written since creation; changes whenever new audio has arrived.
    public var totalWritten: Int { head.load(ordering: .acquiring) }

    /// Writer side: appends `count` mono samples.
    public func write(_ samples: UnsafePointer<Float>, count: Int) {
        var h = head.load(ordering: .relaxed)
        for i in 0..<count {
            storage[h & mask] = samples[i]
            h &+= 1
        }
        head.store(h, ordering: .releasing)
    }

    /// Writer side: appends `frameCount` frames of planar `channels`, averaged to mono.
    public func write(
        downmixing channels: UnsafePointer<UnsafeMutablePointer<Float>>, channelCount: Int, frameCount: Int
    ) {
        guard channelCount > 0 else { return }
        var h = head.load(ordering: .relaxed)
        let gain = 1 / Float(channelCount)
        for i in 0..<frameCount {
            var sum: Float = 0
            for c in 0..<channelCount { sum += channels[c][i] }
            storage[h & mask] = sum * gain
            h &+= 1
        }
        head.store(h, ordering: .releasing)
    }

    /// Reader side: fills `buffer` with the most recent `buffer.count` samples, oldest first; samples that were
    /// never written read as 0. Returns false (leaving `buffer` unspecified) if the writer lapped the copy twice.
    public func copyRecent(into buffer: UnsafeMutableBufferPointer<Float>) -> Bool {
        let count = buffer.count
        guard count > 0, count <= capacity / 2 else { return count == 0 }
        for _ in 0..<2 {
            let end = head.load(ordering: .acquiring)
            let start = end - count
            for i in 0..<count {
                let index = start + i
                buffer[i] = index < 0 ? 0 : storage[index & mask]
            }
            // Everything before `after - capacity` may have been overwritten while copying.
            let after = head.load(ordering: .acquiring)
            if start >= after - capacity { return true }
        }
        return false
    }
}
