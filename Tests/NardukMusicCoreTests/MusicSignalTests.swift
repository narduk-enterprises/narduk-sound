import Foundation
import NardukMusicCore
import Testing

/// The generic input: a source that sets its own level, pins a character and sends cues, with no traffic in sight.
@Suite struct MusicSignalTests {
    static let settings = SongSettings(bpm: 140, genre: .dubstep, seed: 99)

    /// Runs `bars` bars, feeding `signal(step)` once per step.
    static func play(bars: Int, _ signal: (Int) -> MusicSignal?) -> (DropConductor, [ScheduledNote]) {
        var conductor = DropConductor(settings: settings)
        var notes: [ScheduledNote] = []
        for step in 0..<(bars * settings.stepsPerBar) {
            if let signal = signal(step) { conductor.ingest(signal) }
            notes += conductor.advance(throughStep: step)
        }
        return (conductor, notes)
    }

    @Test func aHighLevelBuildsAndDropsWithoutAnyFlow() {
        var sections: Set<SongSection> = []
        var conductor = DropConductor(settings: Self.settings)
        for step in 0..<(64 * Self.settings.stepsPerBar) {
            conductor.ingest(MusicSignal(level: step < 16 ? 0.05 : 0.95, levelLabel: "CPU"))
            _ = conductor.advance(throughStep: step)
            sections.insert(conductor.snapshot.section)
        }
        #expect(sections.contains(.build))
        #expect(sections.contains { $0 == .drop || $0 == .drop2 }, "\(sections)")
        #expect(conductor.snapshot.levelLabel == "CPU")
    }

    @Test func releasingTheLevelHandsEnergyBackToTheFlow() {
        var conductor = DropConductor(settings: Self.settings)
        for step in 0..<64 {
            conductor.ingest(MusicSignal(level: 1, levelLabel: "heat 100%"))
            _ = conductor.advance(throughStep: step)
        }
        let held = conductor.snapshot.energy
        conductor.releaseLevel()
        #expect(conductor.snapshot.levelLabel == nil)
        for step in 64..<(64 * 16) { _ = conductor.advance(throughStep: step) }
        #expect(conductor.snapshot.energy < held / 2, "energy \(conductor.snapshot.energy) from \(held)")
    }

    @Test func aCharacterHintHoldsUntilCleared() {
        // The hint still passes the characterizer's hysteresis (a few seconds), so give it eight bars.
        var conductor = DropConductor(settings: Self.settings)
        conductor.ingest(MusicSignal(character: .surge))
        for step in 0..<128 { _ = conductor.advance(throughStep: step) }
        #expect(conductor.character == .surge)
        conductor.clearCharacterHint()
        for step in 128..<(64 * 8) { _ = conductor.advance(throughStep: step) }
        #expect(conductor.character == .idle)
    }

    @Test func cuesPlayAndNameTheirSource() {
        let (conductor, notes) = Self.play(bars: 8) { step in
            step % 16 == 0 ? MusicSignal(cues: [.spark("swiftc"), .voice("agent")], pan: 0.4) : nil
        }
        #expect(notes.contains { $0.instrument == .laser })
        #expect(conductor.snapshot.legend.contains("laser ← swiftc"), "\(conductor.snapshot.legend)")
    }

    @Test func theSameSignalsWriteTheSameNotes() {
        let signal: (Int) -> MusicSignal? = { step in
            MusicSignal(
                level: Double(step % 97) / 97, flow: MusicFlow(starts: Double(step % 3), sources: ["make": 1]),
                cues: step % 5 == 0 ? [.tick("poll"), .stutter("warning")] : [], pan: step % 2 == 0 ? -0.5 : 0.5)
        }
        let first = Self.play(bars: 32, signal).1
        let second = Self.play(bars: 32, signal).1
        #expect(first == second)
        #expect(first.count > 500)
    }

    @Test func charactersReadTheirCaseNameOrTheirTrafficName() throws {
        let decoded = try JSONDecoder().decode(
            [MusicCharacter].self, from: Data(#"["busy","browsing","steady","call","surge","download","chaos"]"#.utf8))
        #expect(decoded == [.busy, .busy, .steady, .steady, .surge, .surge, .chaos])
        let encoded = try JSONEncoder().encode([MusicCharacter.busy, .surge])
        #expect(String(decoding: encoded, as: UTF8.self) == #"["busy","surge"]"#)
        // The raw values seed each track, so they must never change.
        #expect(MusicCharacter.allCases.map(\.rawValue) == ["idle", "browsing", "call", "download", "chaos"])
    }

    @Test func cuesRoundTripThroughJSON() throws {
        let signal = MusicSignal(
            time: 1.5, level: 0.4, levelLabel: "CPU 40%", flow: MusicFlow(inbound: 10, sources: ["ld": 3]),
            cues: [.zap("ping", height: 0.7, pan: -1), .voice("agent", variant: 2)], pan: 0.2, character: .steady)
        let data = try JSONEncoder().encode(signal)
        #expect(try JSONDecoder().decode(MusicSignal.self, from: data) == signal)
    }
}
