import NardukMusicCore
import NardukMusicEngine
import Testing

/// Picking Ambient must play the ambient family song, not the classic demo loop (narduk-libs#1623). These tests run
/// headless: nothing is hosted, started or played.
@MainActor @Suite struct AmbientRouteTests {
    /// Every note a `SongPlayer` writes for `style` over its first `bars` bars.
    static func notes(for style: GallerySongStyle, bars: Int = 48) -> [ScheduledNote] {
        let song = GallerySong(style: style, seed: 7)
        let player = SongPlayer(song: song, engine: DropEngine())
        var notes: [ScheduledNote] = []
        for bar in 1...bars { notes += player.notes(through: bar * song.settings.stepsPerBar - 1) }
        return notes
    }

    @Test func onlyTheClassicDemoPlaysTheBuiltInLoop() {
        for style in GallerySongStyle.all {
            #expect(style.playsClassicLoop == (style.id == GallerySongStyle.demo.id), "\(style.title)")
        }
        #expect(!GallerySongStyle.ambient.playsClassicLoop)
    }

    @Test func ambientRunsTheAmbientFamilyThroughTheConductor() {
        let settings = GallerySong(style: .ambient, seed: 7).settings
        #expect(settings.family == .ambient)
        #expect(GallerySongStyle.ambient.usesConductor)
    }

    @Test func theAmbientSongWritesPadsAndDronesAndNoDrums() {
        let notes = Self.notes(for: .ambient)
        let voices = Set(notes.filter { $0.instrument == .keys }.compactMap(\.params.voice))
        #expect(voices.contains(KeysVoice.ambientPad), "no ambient pad notes: the route is not the family song")
        #expect(voices.contains(KeysVoice.drone), "no drone notes")
        let drums: Set<Instrument> = [.kick, .snare, .hat, .openHat]
        #expect(!notes.contains { drums.contains($0.instrument) }, "the ambient song wrote drums")
    }

    @Test func aGenreSongStillWritesDrumsSoTheAmbientCheckMeansSomething() {
        let notes = Self.notes(for: .genre(.house))
        #expect(notes.contains { $0.instrument == .kick })
        #expect(!notes.contains { $0.params.voice == KeysVoice.ambientPad })
    }
}
