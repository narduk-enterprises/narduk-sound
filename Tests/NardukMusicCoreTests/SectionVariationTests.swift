import Foundation
import Testing

@testable import NardukMusicCore

/// Long sections must not sit still (narduk-sound#40): a riddim intro of 39 bars on one 2-bar loop, a dubstep drop of
/// one bar played 16 times and 16-bar funk builds at one level were the reports. Builds ramp bar by bar, drops vary
/// inside the phrase, and an intro adds or rotates a layer every phrase after its second.
@Suite struct SectionVariationTests {
    static let genres: [Genre] = [.dubstep, .riddim, .funk, .house, .techno]
    static let seeds: [UInt64] = (1...20).map { $0 &* 0x2545_F491_4F6C_DD1D &+ 0x40 }

    /// One bar as it was written: its section and its notes.
    struct Bar {
        var section: SongSection
        var notes: [ScheduledNote]
    }

    /// The level the source reports for each phrase: a long quiet intro, a rising build, a loud stretch of drops, a
    /// breather, then the same again. Flat stretches are flat on purpose, so a repeated bar is the arrangement's doing
    /// and not the energy's.
    static func level(phrase: Int) -> Double {
        switch phrase {
        case 0..<5: 0.12
        case 5..<8: 0.5 + 0.25 * Double(phrase - 5)
        case 8..<14: 0.95
        case 14..<16: 0.3
        case 16..<19: 0.5 + 0.25 * Double(phrase - 16)
        default: 0.95
        }
    }

    static func play(_ genre: Genre, seed: UInt64, phrases: Int = 25) -> [Bar] {
        var settings = SongSettings(genre: genre)
        settings.seed = seed
        var c = DropConductor(settings: settings)
        let perBar = c.settings.stepsPerBar
        let barsPerPhrase = c.settings.barsPerPhrase
        var bars: [Bar] = []
        var seconds = 0.0
        for bar in 0..<(phrases * barsPerPhrase) {
            let phrase = bar / barsPerPhrase
            let next = phrase + 1 < phrases ? level(phrase: phrase + 1) : level(phrase: phrase)
            let along = Double(bar % barsPerPhrase) / Double(barsPerPhrase)
            c.ingest(MusicSignal(time: seconds, level: level(phrase: phrase) + (next - level(phrase: phrase)) * along))
            let notes = c.advance(throughStep: (bar + 1) * perBar - 1)
            seconds += Double(perBar) * c.settings.secondsPerStep
            bars.append(Bar(section: c.snapshot.section, notes: notes))
        }
        return bars
    }

    /// What a bar sounds like, position by position: the instrument, pitch, length and rounded velocity of every note.
    /// Ghost snares are left out: a seeded ghost note does not make a looped bar sound new.
    static func fingerprint(_ bar: Bar, perBar: Int) -> [String] {
        bar.notes.filter { !($0.instrument == .snare && $0.velocity < 0.32) }.map { note in
            let v = Int((note.velocity * 20).rounded())
            return "\(note.step % perBar) \(note.instrument) \(note.params.pitch ?? -1) \(note.params.lengthSteps) \(v)"
        }.sorted()
    }

    /// The longest stretch of bars inside `sections` that is one bar, or one pair of bars, played again and again.
    static func longestLoop(_ bars: [Bar], in sections: Set<SongSection>, perBar: Int) -> (bars: Int, at: Int) {
        let prints = bars.map { fingerprint($0, perBar: perBar) }
        var best = (bars: 0, at: 0)
        for period in 1...2 {
            var run = 0
            for index in bars.indices {
                let inside = sections.contains(bars[index].section)
                if inside, index >= period, sections.contains(bars[index - period].section),
                    prints[index] == prints[index - period]
                {
                    run += 1
                    if run + period > best.bars { best = (run + period, index) }
                } else {
                    run = 0
                }
            }
        }
        return best
    }

    @Test(arguments: genres)
    func dropsAndIntrosNeverLoopOneBarOrPairPastFourBars(genre: Genre) {
        let perBar = SongSettings(genre: genre).stepsPerBar
        var drops = 0
        var intros = 0
        for seed in Self.seeds {
            let bars = Self.play(genre, seed: seed)
            drops += bars.filter { $0.section.isDrop }.count
            intros += bars.filter { $0.section == .intro }.count
            let drop = Self.longestLoop(bars, in: [.drop, .drop2], perBar: perBar)
            #expect(drop.bars <= 4, "\(genre) seed \(seed): drop loops \(drop.bars) bars, ending at bar \(drop.at)")
            let intro = Self.longestLoop(bars, in: [.intro], perBar: perBar)
            #expect(intro.bars <= 4, "\(genre) seed \(seed): intro loops \(intro.bars) bars, ending at bar \(intro.at)")
        }
        #expect(drops >= 20 * 40, "\(genre): \(drops) drop bars over 20 seeds")
        #expect(intros >= 20 * 32, "\(genre): \(intros) intro bars over 20 seeds")
    }

    /// The drums of a build bar: how hard and how much the kit plays.
    static func drive(_ bar: Bar) -> Double {
        bar.notes.filter { [.kick, .snare, .hat, .openHat].contains($0.instrument) }.reduce(0) { $0 + $1.velocity }
    }

    @Test(arguments: genres)
    func buildsRampFromTheirFirstBarToTheirLast(genre: Genre) {
        var builds = 0
        for seed in Self.seeds {
            let bars = Self.play(genre, seed: seed)
            var start: Int?
            for index in bars.indices {
                let building = bars[index].section == .build
                if building, start == nil { start = index }
                let ends = index == bars.count - 1 || bars[index + 1].section != .build
                guard building, ends, let first = start else { continue }
                start = nil
                guard index < bars.count - 1 else { continue }  // cut off by the end of the run
                builds += 1
                let drives = bars[first...index].map(Self.drive)
                let length = index - first + 1
                #expect(length <= 16, "\(genre) seed \(seed): a \(length)-bar build at bar \(first)")
                #expect(
                    drives.last! > drives.first! * 1.3,
                    "\(genre) seed \(seed): build at bar \(first) drives \(drives.map { Int($0 * 10) })")
                for (a, b) in zip(drives, drives.dropFirst()) {
                    #expect(b >= a - 0.05, "\(genre) seed \(seed): build at bar \(first) eases off: \(drives)")
                }
            }
        }
        #expect(builds >= 20, "\(genre): \(builds) builds over 20 seeds")
    }

    /// Each genre arrives at its drops in its own one of a few forms, not one riser, roll and impact for all.
    @Test func dropsArriveInTheGenresOwnForm() {
        let forms: [(Genre, GenreArrangement.DropEntry)] = [
            (.dubstep, .slam), (.house, .filterOpen), (.synthwave, .pickup), (.funk, .bandFill),
            (.tropicalHouse, .filterOpen),
        ]
        for (genre, form) in forms {
            #expect(GenreArrangement.dropEntry(genre) == form)
            var risers = 0
            var impacts = 0
            var crashes = 0
            var arrivals = 0
            for seed in Self.seeds.prefix(5) {
                let bars = Self.play(genre, seed: seed)
                for index in bars.indices.dropFirst()
                where bars[index].section.isDrop && !bars[index - 1].section.isDrop {
                    arrivals += 1
                    risers += bars[index - 1].notes.filter { $0.instrument == .riser }.count
                    impacts += bars[index].notes.filter { $0.instrument == .impact && $0.step % 16 == 0 }.count
                    crashes += bars[index].notes.filter { $0.instrument == .openHat && $0.step % 16 == 0 }.count
                }
            }
            #expect(arrivals >= 5, "\(genre): \(arrivals) drop arrivals")
            switch form {
            case .slam:
                #expect(risers >= arrivals && impacts >= arrivals, "\(genre): \(risers) risers, \(impacts) impacts")
            case .pickup:
                #expect(risers >= arrivals && impacts >= arrivals, "\(genre): \(risers) risers, \(impacts) impacts")
            case .filterOpen, .none:
                #expect(risers == 0 && impacts == 0, "\(genre): \(risers) risers, \(impacts) impacts")
            case .bandFill:
                #expect(risers == 0 && impacts == 0 && crashes > 0, "\(genre): \(impacts) impacts, \(crashes) crashes")
            }
        }
    }

    /// The master cut ends only some drop phrases, as the genre punctuates; band genres never cut.
    @Test func cutsPunctuateSomeDropPhrasesOnly() {
        let phrases = 0..<8
        #expect(phrases.filter { GenreArrangement.cutsOnDropPhrase(.dubstep, phraseInSection: $0) }.count == 4)
        #expect(phrases.filter { GenreArrangement.cutsOnDropPhrase(.house, phraseInSection: $0) }.count == 2)
        #expect(phrases.allSatisfy { !GenreArrangement.cutsOnDropPhrase(.funk, phraseInSection: $0) })
        #expect(GenreArrangement.stuttersIntoDrop(.riddim) && !GenreArrangement.stuttersIntoDrop(.techno))
    }
}
