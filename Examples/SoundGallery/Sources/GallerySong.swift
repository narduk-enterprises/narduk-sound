import Foundation
import NardukMusicCore
import NardukMusicEngine

/// What the "Demo song" source plays. `demo` is the built-in eight-bar loop; a genre is written live by the conductor
/// from a scripted energy curve; `guitars` is a hand-written unplugged part for the B1 instruments; `ambient` is a slot
/// for the ambient family (narduk-libs#1576), listed but not playable until that lands.
enum GallerySongStyle: Hashable, Identifiable {
    case demo
    case genre(Genre)
    case guitars
    case ambient

    var id: String {
        switch self {
        case .demo: "demo"
        case .genre(let genre): "genre-\(genre.rawValue)"
        case .guitars: "guitars"
        case .ambient: "ambient"
        }
    }

    var title: String {
        switch self {
        case .demo: "Classic demo loop"
        case .genre(let genre): genre.shortName
        case .guitars: "Guitars (unplugged to electric)"
        case .ambient: "Ambient (coming soon)"
        }
    }

    /// False for the ambient slot until the ambient family exists.
    var isPlayable: Bool { self != .ambient }

    /// Every entry the picker shows, in order.
    static var all: [GallerySongStyle] {
        [.demo] + Genre.allCases.map(GallerySongStyle.genre) + [.guitars, .ambient]
    }
}

/// One song to play: a style and the seed that makes it different from the next one.
struct GallerySong: Hashable {
    var style: GallerySongStyle = .demo
    var seed: UInt64 = SongSettings.sessionSeed()

    /// The song settings the engine runs. Each genre plays at its own tempo; the guitars sit at a relaxed 96.
    var settings: SongSettings {
        switch style {
        case .genre(let genre):
            var settings = SongSettings(genre: genre)
            settings.seed = seed
            return settings
        case .guitars:
            var settings = SongSettings(genre: .chill)
            settings.bpm = 96
            settings.seed = seed
            return settings
        case .demo, .ambient:
            return SongSettings()
        }
    }

    mutating func reroll() { seed = SongSettings.sessionSeed() &+ seed &* 0x9E37_79B9_7F4A_7C15 }
}
