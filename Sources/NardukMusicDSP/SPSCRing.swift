import NardukMusicCore
import Synchronization

/// A bounded, lock-free single-producer / single-consumer ring of trivially copyable
/// values. The producer (the main actor) pushes, the consumer (the audio render thread)
/// pops; neither side allocates, locks or touches reference counts. A push into a full
/// ring is dropped and reported, never blocks.
public final class SPSCRing<Element: BitwiseCopyable>: @unchecked Sendable {
    public let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Element>
    /// Total elements ever written (owned by the producer).
    private let head = Atomic<Int>(0)
    /// Total elements ever read (owned by the consumer).
    private let tail = Atomic<Int>(0)

    /// `capacity` is rounded up to a power of two.
    public init(capacity: Int) {
        var size = 1
        while size < max(capacity, 2) { size <<= 1 }
        self.capacity = size
        self.mask = size - 1
        self.storage = UnsafeMutablePointer<Element>.allocate(capacity: size)
    }

    deinit {
        storage.deallocate()
    }

    /// Producer side. Returns false (and drops `element`) when the ring is full.
    @discardableResult
    public func push(_ element: Element) -> Bool {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        guard h - t < capacity else { return false }
        (storage + (h & mask)).initialize(to: element)
        head.store(h + 1, ordering: .releasing)
        return true
    }

    /// Consumer side. Returns nil when the ring is empty.
    public func pop() -> Element? {
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        guard t != h else { return nil }
        let element = storage[t & mask]
        tail.store(t + 1, ordering: .releasing)
        return element
    }

    /// An approximate fill level (exact when called from either single side while the other is idle).
    public var count: Int {
        head.load(ordering: .acquiring) - tail.load(ordering: .acquiring)
    }
}
