import Dispatch
import Foundation
import NardukMusicCore
import NardukMusicDSP
import Synchronization

/// The render block's alarm: it signals after every buffer, which neither allocates nor blocks (a semaphore signal),
/// and the pump thread waits on it. So the pump follows the audio clock, not a run loop.
final class PumpWake: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    @inline(__always) func signal() { semaphore.signal() }

    /// Waits for the next buffer, or `timeout` (a backstop if nothing renders or no block signals).
    func wait(timeout: DispatchTimeInterval) { _ = semaphore.wait(timeout: .now() + timeout) }
}

/// A dedicated thread that runs `work` after every rendered buffer until cancelled.
final class LivePump: Sendable {
    private let running = Atomic<Bool>(true)
    private let wake: PumpWake

    /// The longest the thread waits for a buffer before it pumps anyway.
    static let backstop = DispatchTimeInterval.milliseconds(25)

    init(wake: PumpWake, work: @escaping @Sendable () -> Void) {
        self.wake = wake
        let thread = Thread { [self] in
            while running.load(ordering: .acquiring) {
                wake.wait(timeout: Self.backstop)
                guard running.load(ordering: .acquiring) else { break }
                work()
            }
        }
        thread.name = "NardukSound.ConductorDriver"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Stops the thread after its current pass.
    func cancel() {
        running.store(false, ordering: .releasing)
        wake.signal()
    }
}

/// The one producer into a synth's event ring, and the tracker of the pitched notes handed to it. The ring has a single
/// producer, and both the pump thread and the main actor (`cut`, the vocal riser) push, so every push holds this lock.
/// The render thread never takes it.
final class NoteFeed: Sendable {
    private let tracker = Mutex(NoteTracker())

    /// Writes `driver`'s due notes into `core`.
    func pump(_ driver: ConductorDriver, into core: DropSynthCore) {
        tracker.withLock { tracker in
            _ = driver.write(into: core) { note in
                core.schedule(note)
                tracker.schedule(note)
            }
        }
    }

    /// Schedules `notes` (already on the synth's clock) and returns how many the ring took.
    @discardableResult
    func push(_ notes: [ScheduledNote], to core: DropSynthCore, track: Bool = true) -> Int {
        tracker.withLock { tracker in
            var taken = 0
            for note in notes {
                if core.schedule(note) { taken += 1 }
                if track { tracker.schedule(note) }
            }
            return taken
        }
    }

    /// Runs `body` (a `cut`) as the ring's producer.
    func produce<T: Sendable>(_ body: () -> T) -> T { tracker.withLock { _ in body() } }

    func reset() { tracker.withLock { $0.reset() } }

    /// Moves the tracker to the audible step position and returns what is sounding.
    func advance(to position: Double) -> (held: NoteSet, counters: NoteCounters) {
        tracker.withLock { tracker in
            tracker.advance(to: position)
            return (tracker.held, tracker.counters)
        }
    }
}
