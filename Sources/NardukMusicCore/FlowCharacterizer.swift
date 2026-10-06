import Foundation

// Classifies what the input has sounded like over the last ten to thirty seconds (Wirewatcher #45 follow-up: "input
// changes don't change the tune"). Energy says how loud; character says what kind: steady both ways (a video call), a
// one-way surge (a download), busy bursts (browsing), idle chatter or a burst of faults. The conductor lets the
// character pick the next track and steer the current one. Pure and clock-free like the conductor: it is fed per step
// with that step's share of the flow and its length. A source can pin the character with a hint instead.

struct FlowCharacterizer: Sendable {
    /// Seconds a new character must persist before it replaces the current one.
    static let hysteresis = 6.0
    /// Time constant of the rate averages: about ten seconds of memory.
    static let memory = 10.0

    private(set) var current: MusicCharacter = .idle
    private(set) var candidate: MusicCharacter = .idle
    /// A character the source has pinned; it replaces the classification (hysteresis still applies).
    var hint: MusicCharacter?
    private var candidateSeconds = 0.0
    private var elapsed = 0.0

    private(set) var inRate = 0.0
    private(set) var outRate = 0.0
    /// Both directions over the last few seconds: silence is heard sooner than the ten-second averages fall.
    private(set) var recentRate = 0.0
    /// New connections, lookups and handshakes per second.
    private(set) var connectionRate = 0.0
    /// Resets, retransmissions, failed lookups and unreachables per second.
    private(set) var errorRate = 0.0
    /// Mean change of one-second throughput, in decades, over the last few seconds: about 0 for a steady stream, 0.5
    /// or more for page loads. A single step up or down (a download starting) moves it only a little.
    private(set) var burstiness = 0.0
    private var second = 0.0
    private var secondBytes = 0.0
    private var recentSeconds: [Double] = []
    static let burstWindow = 8
    static let burstyAbove = 0.3

    /// Feeds one step: its bytes each way, its connection and error events, and how long it lasted.
    mutating func observe(bytesIn: Double, bytesOut: Double, connections: Double, errors: Double, seconds: Double) {
        guard seconds > 0 else { return }
        elapsed += seconds
        // Faster averages for the first seconds of a session, so the first track already hears the room.
        let tau = min(Self.memory, max(2, elapsed))
        let k = 1 - exp(-seconds / tau)
        inRate += (bytesIn / seconds - inRate) * k
        outRate += (bytesOut / seconds - outRate) * k
        recentRate += ((bytesIn + bytesOut) / seconds - recentRate) * (1 - exp(-seconds / 2))
        connectionRate += (connections / seconds - connectionRate) * k
        errorRate += (errors / seconds - errorRate) * k

        second += seconds
        secondBytes += bytesIn + bytesOut
        if second >= 1 {
            recentSeconds.append(log10(1 + secondBytes / second))
            if recentSeconds.count > Self.burstWindow { recentSeconds.removeFirst() }
            let changes = zip(recentSeconds, recentSeconds.dropFirst()).map { abs($1 - $0) }
            burstiness = changes.isEmpty ? 0 : changes.reduce(0, +) / Double(changes.count)
            second = 0
            secondBytes = 0
        }

        let now = classify()
        if now == current {
            candidate = now
            candidateSeconds = 0
            return
        }
        if now == candidate {
            candidateSeconds += seconds
        } else {
            candidate = now
            candidateSeconds = seconds
        }
        // The very first reading needs no hysteresis beyond the averages warming up.
        if candidateSeconds >= Self.hysteresis || (elapsed < Self.hysteresis + 2 && elapsed >= 4) {
            current = now
            candidateSeconds = 0
        }
    }

    /// What the averages look like right now, before hysteresis.
    func classify() -> MusicCharacter {
        if let hint { return hint }
        let total = inRate + outRate
        if errorRate >= 1.2 && errorRate >= 0.2 * connectionRate { return .chaos }
        if min(total, recentRate) < 20_000 && connectionRate < 1.5 { return .idle }
        // Traffic collapsing towards silence reads as bursty for a while: hold the current reading until it settles.
        if recentRate < 0.2 * total { return current }
        let inShare = total > 0 ? inRate / total : 0.5
        let symmetry = max(inRate, outRate) > 0 ? min(inRate, outRate) / max(inRate, outRate) : 0
        if inShare > 0.85 && total > 1_500_000 && burstiness < Self.burstyAbove && connectionRate < 4 { return .surge }
        if symmetry > 0.3 && burstiness < Self.burstyAbove && connectionRate < 3 { return .steady }
        return .busy
    }
}
