import Foundation
import NardukMusicCore
import NardukMusicDSP
import NardukMusicRender
import Testing

/// Golden renders for the guitars (narduk-libs#1574): each scenario in `scenarios/instruments` names one instrument
/// (the strums two chords' worth) and renders to exactly the same samples every time. As with `GoldenRenderTests`,
/// libm may differ in the last bit between platforms, so each platform has its own fingerprint. When a guitar changes on
/// purpose, listen to `narduk-music render --scenario scenarios/instruments/<name>.json --out /tmp/x.wav`, read the
/// new fingerprint from the failure, and update it here.
@Suite struct InstrumentGoldenTests {
    struct Case: Sendable, CustomTestStringConvertible {
        var name: String
        var instrument: Instrument
        var goldens: [String: UInt64]
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(
            name: "acoustic-guitar", instrument: .acousticGuitar,
            goldens: ["darwin-arm64": 0xde7a_9c8a_4cb1_3e6a, "linux-x86_64": 0xde7a_9c8a_4cb1_3e6a]),
        Case(
            name: "electric-guitar", instrument: .electricGuitar,
            goldens: ["darwin-arm64": 0xbf3f_250a_7b02_d5d7, "linux-x86_64": 0xbf3f_250a_7b02_d5d7]),
        Case(
            name: "bass-guitar", instrument: .bassGuitar,
            goldens: ["darwin-arm64": 0xf0f6_4f2d_f1fa_6b65, "linux-x86_64": 0xf0f6_4f2d_f1fa_6b65]),
        Case(
            name: "acoustic-strum", instrument: .strum,
            goldens: ["darwin-arm64": 0x1ec6_d424_f18a_8e26, "linux-x86_64": 0x3349_73e0_e737_2578]),
        Case(
            name: "electric-strum", instrument: .electricStrum,
            goldens: ["darwin-arm64": 0x888e_213a_1a5a_958b, "linux-x86_64": 0x888e_213a_1a5a_958b]),
    ]

    static func scenario(_ name: String, folder: String = "instruments/") throws -> MusicScenario {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scenarios/\(folder)\(name).json")
        return try MusicScenario.load(Data(contentsOf: url))
    }

    @Test(arguments: cases)
    func eachInstrumentMatchesItsGoldenFingerprint(_ item: Case) throws {
        let scenario = try Self.scenario(item.name)
        #expect(scenario.notes?.allSatisfy { $0.instrument == item.instrument } == true)
        let audio = OfflineRenderer.render(scenario)
        #expect(audio.left.allSatisfy(\.isFinite) && audio.right.allSatisfy(\.isFinite))
        #expect(audio.peak > 0.1 && audio.peak <= DSP.ceiling, "\(item.name) peak \(audio.peak)")
        let actual = String(format: "0x%016llx", audio.fingerprint)
        let golden = try #require(
            item.goldens[GoldenRenderTests.platform], "no golden for \(GoldenRenderTests.platform); actual \(actual)")
        #expect(audio.fingerprint == golden, "\(item.name) \(GoldenRenderTests.platform) fingerprint \(actual)")
    }

    @Test(arguments: cases)
    func theInstrumentIsAudibleAndReportsItself(_ item: Case) throws {
        let renderer = OfflineRenderer(settings: try Self.scenario(item.name).settings(), playsConductor: false)
        renderer.schedule(try Self.scenario(item.name).scheduledNotes(settings: renderer.settings))
        var hits: Set<Instrument> = []
        var energy: Float = 0
        for _ in 0..<(3 * 60) {
            let block = renderer.advance()
            energy += block.left.reduce(0) { $0 + $1 * $1 }
            hits.formUnion(renderer.takeHits())
        }
        #expect(energy > 1, "\(item.name) rendered \(energy)")
        #expect(hits == [item.instrument], "\(item.name) reported \(hits)")
    }

    @Test func scenarioNotesNameEveryNewInstrument() throws {
        var named: Set<Instrument> = []
        for item in Self.cases { named.formUnion(try Self.scenario(item.name).notes?.map(\.instrument) ?? []) }
        #expect(named == Set(Instrument.allCases.filter { $0.synthCode >= 14 }))
    }

    @Test func theDemoPlaysGuitarsOverAConductorBed() throws {
        let scenario = try Self.scenario("guitar-demo", folder: "")
        let renderer = OfflineRenderer(settings: scenario.settings())
        renderer.schedule(scenario.scheduledNotes(settings: renderer.settings))
        var hits: Set<Instrument> = []
        var signals = scenario.timeline()[...]
        for tick in 0..<(20 * 60) {
            let end = Double(tick + 1) / OfflineRenderer.tickRate
            var arrived: [MusicSignal] = []
            while let signal = signals.first, signal.time < end {
                arrived.append(signal)
                signals = signals.dropFirst()
            }
            _ = renderer.advance(signals: arrived)
            hits.formUnion(renderer.takeHits())
        }
        #expect(hits.isSuperset(of: [.strum, .bassGuitar, .acousticGuitar]), "\(hits)")
        #expect(hits.contains(.kick) || hits.contains(.hat), "the conductor's bed should play too: \(hits)")
    }

    @Test func notesDecodeFromJSONAndLandOnTheGrid() throws {
        let json = """
            { "bpm": 120, "notes": [
              { "time": 0.5, "instrument": "strum", "pitch": 45, "chord": "minor", "direction": "up", "length": 1 },
              { "time": 0.1875, "instrument": "electricGuitar", "pitch": 52, "drive": 0.8 } ] }
            """
        let scenario = try MusicScenario.load(Data(json.utf8))
        let notes = scenario.scheduledNotes(settings: scenario.settings())
        #expect(notes.count == 2)
        // Sorted by time: 0.1875 s is 1.5 steps at 120 bpm (0.125 s a step), 0.5 s is step 4.
        #expect(notes[0].instrument == .electricGuitar && notes[0].step == 1 && notes[0].params.delay == 0.5)
        #expect(notes[0].params.drive == 0.8 && notes[0].params.lengthSteps == 4)
        #expect(notes[1].instrument == .strum && notes[1].step == 4 && notes[1].params.delay == nil)
        #expect(notes[1].params.voice == StrumChord.minor.voice && notes[1].params.formant == 1)
        #expect(notes[1].params.lengthSteps == 8)
    }

    @Test func aScenarioWithoutNotesIsUnchanged() throws {
        let scenario = try GoldenRenderTests.scenario()
        #expect(scenario.notes == nil && scenario.scheduledNotes(settings: scenario.settings()).isEmpty)
    }
}
