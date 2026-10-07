import Testing

@testable import NardukMusicCore

/// `requestNextTrack`: the hand-over plays out the phrase with an outro and lands on the next phrase line.
struct NextTrackTests {
    private static func conductor(_ genre: Genre = .house) -> DropConductor {
        var settings = SongSettings(genre: genre)
        settings.seed = 7
        var c = DropConductor(settings: settings)
        c.ingest(MusicSignal(time: 0, level: 0.5))
        return c
    }

    /// Writes one step at a time until `body` returns true or `limit` steps pass; returns the step it stopped on.
    private static func run(_ c: inout DropConductor, from: Int, limit: Int, until body: (DropConductor, Int) -> Bool)
        -> Int?
    {
        for step in from..<(from + limit) {
            _ = c.advance(throughStep: step)
            if body(c, step) { return step }
        }
        return nil
    }

    @Test func theNewTrackStartsOnThePhraseLineAfterAnOutro() throws {
        var c = Self.conductor()
        let phrase = c.settings.stepsPerPhrase
        // Into the first phrase, well before its last bar.
        _ = c.advance(throughStep: 20)
        let first = try #require(c.snapshot.track?.number)
        c.requestNextTrack()
        #expect(c.requestedNextTrack.pending)
        var legends: [String] = []
        let changed = try #require(
            Self.run(&c, from: 21, limit: 4 * phrase) { c, _ in
                legends += c.snapshot.legend
                return c.snapshot.track?.number != first
            })
        #expect(changed == phrase)
        #expect(c.activeGenre == .house)
        #expect(!c.requestedNextTrack.pending)
        #expect(legends.contains { $0.contains("← next track") })
    }

    @Test func aRequestedGenreLandsWithTheNewTrackNotBefore() throws {
        var c = Self.conductor(.house)
        let phrase = c.settings.stepsPerPhrase
        _ = c.advance(throughStep: 20)
        c.requestNextTrack(genre: .techno)
        #expect(c.pendingGenre == nil)  // no bar-line cut
        let changed = try #require(Self.run(&c, from: 21, limit: 4 * phrase) { c, _ in c.activeGenre == .techno })
        #expect(changed == phrase)
        let change = try #require(c.lastSwitch)
        #expect(change.genre == .techno)
        #expect(change.step == phrase)
        #expect(change.bpm == c.settings.bpm)
    }

    @Test func aRequestInTheLastBarWaitsForTheNextPhrase() throws {
        var c = Self.conductor()
        let phrase = c.settings.stepsPerPhrase
        let lastBar = phrase - c.settings.stepsPerBar
        _ = c.advance(throughStep: lastBar + 2)
        let first = try #require(c.snapshot.track?.number)
        c.requestNextTrack()
        let changed = try #require(
            Self.run(&c, from: lastBar + 3, limit: 4 * phrase) { c, _ in c.snapshot.track?.number != first })
        #expect(changed == 2 * phrase)
    }

    @Test func setGenreCutsAndCancelsAPendingRequest() {
        var c = Self.conductor()
        _ = c.advance(throughStep: 20)
        c.requestNextTrack(genre: .techno)
        c.setGenre(.funk)
        #expect(c.pendingGenre == .funk)
        _ = c.advance(throughStep: 40)
        #expect(c.activeGenre == .funk)
    }
}
