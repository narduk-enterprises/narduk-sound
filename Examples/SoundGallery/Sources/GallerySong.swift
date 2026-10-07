import Foundation
import NardukMusicCore
import NardukMusicEngine

/// What the "Demo song" source plays. `demo` is the built-in eight-bar loop; a genre is written live by the conductor
/// from a scripted energy curve; `guitars` is a hand-written unplugged part for the B1 instruments; `ambient` is the
/// ambient family (narduk-libs#1576): drones and pads that swell and settle with the energy curve.
enum GallerySongStyle: Hashable, Identifiable {
    case demo
    case genre(Genre)
    case guitars
    case ambient
    /// A song a prompt wrote (`SongRecipe`): its settings and energy script come from the recipe.
    case recipe(SongRecipe)

    var id: String {
        switch self {
        case .demo: "demo"
        case .genre(let genre): "genre-\(genre.rawValue)"
        case .guitars: "guitars"
        case .ambient: "ambient"
        case .recipe: "recipe"
        }
    }

    var title: String {
        switch self {
        case .demo: "Classic demo loop"
        case .genre(let genre): genre.shortName
        case .guitars: "Guitars (unplugged to electric)"
        case .ambient: "Ambient (swell and settle)"
        case .recipe(let recipe): recipe.title
        }
    }

    /// Whether the conductor writes this style (every genre and the ambient family do).
    var usesConductor: Bool {
        switch self {
        case .genre, .ambient, .recipe: true
        case .demo, .guitars: false
        }
    }

    /// Whether this style is the built-in eight-bar loop (`DropEngine.playDemo`). Every other style is written live by
    /// a `SongPlayer`: sending one to `playDemo` plays the loop under the wrong name (narduk-libs#1623).
    var playsClassicLoop: Bool {
        if case .demo = self { return true }
        return false
    }

    /// Every entry the picker shows, in order.
    static var all: [GallerySongStyle] {
        [.demo] + Genre.allCases.map(GallerySongStyle.genre) + [.guitars, .ambient]
    }
}

/// One song to play: a style and the seed that makes it different from the next one.
struct GallerySong: Hashable {
    var style: GallerySongStyle = .demo
    var seed: UInt64 = SongSettings.sessionSeed()

    /// The song settings the engine runs. Each genre plays at its own tempo; the guitars sit at a relaxed 96 and the
    /// ambient family drifts at 72.
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
        case .ambient:
            var settings = SongSettings(genre: .chill, family: .ambient)
            settings.bpm = 72
            settings.seed = seed
            return settings
        case .recipe(let recipe):
            var settings = recipe.settings()
            settings.seed = seed
            return settings
        case .demo:
            return SongSettings()
        }
    }

    mutating func reroll() { seed = SongSettings.sessionSeed() &+ seed &* 0x9E37_79B9_7F4A_7C15 }
}
