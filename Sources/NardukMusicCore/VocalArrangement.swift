import Foundation

// Wordless vocals and cuts in an arrangement (narduk-libs#1641). A track carries a `VocalPlan` only when
// `SongSettings.variety` is above 0 and the track's own draw for the "vocals" or "cuts" axis lands, so with variety 0
// (the default) nothing here adds a note and every song is exactly as it was.

/// What a track's vocals and cuts do, drawn from the track's seed (never from its own random sequence).
struct VocalPlan: Sendable, Hashable {
    /// An "aah" choir pad in the intro, breakdown and build (the genres that suit one), and in the ambient family.
    var pad = false
    /// A vocal-chop hook in the drops, and gated chops through the second half of a build (the genres that suit it).
    var chop = false
    /// A stutter fill into each drop and a cut on the drop's last bar.
    var cuts = false
    var padVowel = VocalVowel.ah
    var chopVowels: [VocalVowel] = [.ah, .oh]
    /// 0 alto ... 1 soprano.
    var register = 0.6
    var breath = 0.25
    /// Where on the bar's 16-step grid the chop hook lands (answer bars shift it by two).
    var chopSteps: [Int] = [3, 6, 10, 14]
    var cutMode = CutMode.stutter
    /// The recorded voice sings a line written from the song's chords and hook (`VocalLine`), with the stack, throws,
    /// swells and syllable answers that go with it.
    var line = false
    var lineVowel = VocalVowel.ah
    var morphVowel: VocalVowel? = .oo
    var lineTechnique = SampleTechnique.vibrato
    var character = VocalCharacter.natural
    /// 0 none, 1 third and fifth, 2 octave and third, 3 third and octave below.
    var harmony = 0
    /// The breakdown's line goes through a radio.
    var radio = false
    /// 0 ... 1, steadies per-track choices (vibrato rate).
    var lineDraw = 0.5
    /// Sampled syllable answers in the drops: a few chops, on the beat, the same slice on the same beat each bar.
    var chops = false
    var chopGrid: [Int] = [0, 8]
    var chopSlices: [Double] = [0.1, 0.6]

    var isEmpty: Bool { !pad && !chop && !cuts && !line }

    static func padGenre(_ genre: Genre) -> Bool { genre == .chill || genre == .house || genre == .synthwave }
    static func chopGenre(_ genre: Genre) -> Bool {
        genre == .dubstep || genre == .trap || genre == .ukGarage || genre == .house
    }
}

extension Variety {
    /// The vocal plan for a track, or nil when none of its three parts is drawn.
    static func vocalPlan(for track: Track, variety: Double) -> VocalPlan? {
        guard variety > 0 else { return nil }
        var plan = VocalPlan()
        var rng = stream(track, "vocals")
        // Always draw, so the shape of the plan never depends on which parts are on.
        let vowels = VocalVowel.allCases.filter { $0 != .mm }
        plan.padVowel = [VocalVowel.ah, .oh, .oo][Int(rng.next() % 3)]
        plan.chopVowels = (0..<3).map { _ in vowels[Int(rng.next() % UInt64(vowels.count))] }
        plan.register = 0.35 + 0.6 * rng.unit()
        plan.breath = 0.1 + 0.35 * rng.unit()
        let patterns: [[Int]] = [
            [3, 6, 10, 14], [2, 5, 8, 11, 14], [0, 3, 6, 9, 12], [4, 7, 10, 15], [2, 6, 11, 14],
        ]
        plan.chopSteps = patterns[Int(rng.next() % UInt64(patterns.count))]
        plan.cutMode = [CutMode.stutter, .stutter, .chop, .reverse][Int(rng.next() % 4)]
        if uses("vocals", track, variety: variety) {
            plan.pad = true  // ambient songs take it whatever their genre; the others only where it suits
            plan.chop = VocalPlan.chopGenre(track.genre)
        }
        if uses("cuts", track, variety: variety), track.genre.family != .band { plan.cuts = true }
        // The sung line draws from a stream of its own, so the parts above keep the draws they always had.
        var lineRng = stream(track, "vocalLine")
        let vowelPool: [VocalVowel] = [.ah, .oh, .ah, .eh]
        plan.lineVowel = vowelPool[Int(lineRng.next() % UInt64(vowelPool.count))]
        plan.morphVowel = [VocalVowel.oo, .oh, nil][Int(lineRng.next() % 3)]
        plan.lineTechnique = [SampleTechnique.vibrato, .vibrato, .straight][Int(lineRng.next() % 3)]
        plan.character = VocalCharacter.allCases[Int(lineRng.next() % UInt64(VocalCharacter.allCases.count))]
        plan.harmony = Int(lineRng.next() % 4)
        plan.radio = lineRng.unit() < 0.5
        plan.lineDraw = lineRng.unit()
        let grids: [[Int]] = [[0, 8], [4, 12], [0, 6, 8], [2, 8, 12], [0, 4, 10]]
        plan.chopGrid = grids[Int(lineRng.next() % UInt64(grids.count))]
        plan.chopSlices = [lineRng.unit() * 0.45, 0.5 + lineRng.unit() * 0.45]
        if uses("vocalLine", track, variety: variety), track.genre.family == .electronic {
            plan.line = true
            plan.chops = VocalPlan.chopGenre(track.genre)
        }
        return plan.isEmpty ? nil : plan
    }
}

enum VocalArrangement {
    /// The vocal and cut notes for this step of an electronic song.
    static func notes(_ c: StepContext) -> [ScheduledNote] {
        guard let plan = c.track.vocals, let pos = c.pos else { return [] }
        var out: [ScheduledNote] = VocalLine.notes(c, plan: plan)
        let level = min(1, max(0, c.level))
        func add(_ instrument: Instrument, _ velocity: Double, _ params: NoteParams) {
            out.append(
                ScheduledNote(
                    step: c.step, instrument: instrument, velocity: min(1, max(0, velocity)), params: params))
        }
        let tones = GenreArrangement.chord(
            c, degree: c.chord, base: c.keyRoot, seventh: GenreArrangement.lush(c.track.genre))

        if plan.pad, VocalPlan.padGenre(c.track.genre) {
            let singsPad: Bool =
                switch c.section {
                case .intro: c.barInPhrase % 4 == 0
                case .breakdown, .build: c.barInPhrase % 2 == 0
                case .drop, .drop2: false
                }
            if pos == 0, singsPad, tones.count >= 3 {
                let velocity = (c.section == .build ? 0.4 : 0.3) + 0.25 * level
                for (n, pitch) in [tones[1], tones[2] + 12].enumerated() {
                    add(
                        .vocal, velocity * (n == 0 ? 1 : 0.8),
                        NoteParams(
                            pitch: pitch, lengthSteps: c.perBar * 2, formant: plan.register * (n == 0 ? 0.7 : 1),
                            drive: plan.breath, voice: NoteParams.vocalVoice(plan.padVowel, style: .choir)))
                }
            }
        }

        if plan.chop {
            if c.section == .build, c.barInPhrase >= c.barsPerPhrase / 2, !c.dropComing || pos < 12 {
                // Gated vocals: short chops on the eighths, one rung higher up the chord each bar.
                if pos % 2 == 0, !tones.isEmpty {
                    let rung = (c.barInPhrase + pos / 2) % tones.count
                    add(
                        .vocalChop, 0.3 + 0.35 * level,
                        NoteParams(
                            pitch: tones[rung] + 12, lengthSteps: 1, formant: plan.register, drive: plan.breath,
                            voice: NoteParams.vocalVoice(plan.chopVowels[(pos / 2) % plan.chopVowels.count]),
                            pan: pos % 4 == 0 ? -0.3 : 0.3))
                }
            }
            if c.section.isDrop {
                let shift = c.barInPhrase % 2 == 1 ? 2 : 0
                if let index = plan.chopSteps.firstIndex(of: (pos + 16 - shift) % 16), !tones.isEmpty {
                    let degreeLift = [0, 2, 1, 3][(index + c.barInPhrase) % 4]
                    add(
                        .vocalChop, 0.5 + 0.3 * level,
                        NoteParams(
                            pitch: tones[degreeLift % tones.count] + 12, lengthSteps: index % 2 == 0 ? 1 : 2,
                            formant: plan.register, drive: plan.breath,
                            voice: NoteParams.vocalVoice(plan.chopVowels[index % plan.chopVowels.count]),
                            pan: index % 2 == 0 ? -0.35 : 0.35))
                }
            }
        }

        if plan.cuts {
            // A stutter fill on the last beat before a drop; a cut on the last bar of each drop phrase.
            if c.dropComing {
                if pos == 12 {
                    add(.cut, 1, .cut(.stutter, division: .sixteenth, steps: 2, amount: 0.6, seed: c.bar))
                } else if pos == 14 {
                    add(.cut, 1, .cut(.stutter, division: .thirtySecond, steps: 2, amount: 0.9, seed: c.bar))
                }
            } else if c.section.isDrop, c.isLastBar, pos == 12 {
                add(.cut, 1, .cut(plan.cutMode, division: .sixteenth, steps: 4, amount: 0.5, seed: c.bar))
            }
        }
        return out
    }

    /// The vocal notes for this step of an ambient song: a choir that blooms with the pads.
    static func ambientNotes(_ c: StepContext, tones: [Int]) -> [ScheduledNote] {
        guard let plan = c.track.vocals, plan.pad, c.pos == 0, tones.count >= 3 else { return [] }
        let level = min(1, max(0, c.level))
        let sings: Bool =
            switch c.section {
            case .intro: false
            case .build: true
            case .drop, .drop2: c.barInPhrase % 2 == 0
            case .breakdown: c.barInPhrase % 4 == 2
            }
        guard sings else { return [] }
        let velocity = 0.22 + 0.3 * level
        return [tones[1] + 12, tones[2] + 12].enumerated().map { n, pitch in
            ScheduledNote(
                step: c.step, instrument: .vocal, velocity: velocity * (n == 0 ? 1 : 0.85),
                params: NoteParams(
                    pitch: pitch, lengthSteps: c.perBar * 2 + c.perBar / 2, formant: plan.register,
                    drive: plan.breath, voice: NoteParams.vocalVoice(plan.padVowel, style: .choir)))
        }
    }
}
