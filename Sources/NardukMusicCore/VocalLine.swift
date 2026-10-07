import Foundation

// The sampled voice as a singer in the song (narduk-libs#1641): one real recording becomes a lead, an answer, a stack
// of harmonies and a set of effect throws, all written from the song's own chords, key and hook. Everything here is a
// pure function of the step's context and the track's seed, so a song sings the same line every time it is rendered,
// and a different song sings a different one. Like the rest of the vocals it is only on behind `SongSettings.variety`.

/// How the line is sung, drawn per track.
enum VocalCharacter: Int, Sendable, Hashable, CaseIterable {
    case natural, power, airy, robot
}

/// What a note of the line is for, which decides how it is expressed.
private struct LineNote {
    var pos: Int
    var length: Int
    var pitch: Int
    /// The last note of the phrase: it falls away and throws an echo.
    var closing = false
    /// A reverse swell into the drop.
    var swell = false
    var strong = false
}

enum VocalLine {
    /// The register the line sits in (MIDI): a female voice, alto to soprano.
    static let low = 62
    static let high = 81

    /// Folds `pitch` into the register by octaves.
    static func fold(_ pitch: Int) -> Int {
        var p = pitch
        while p < low { p += 12 }
        while p > high { p -= 12 }
        return p
    }

    /// The notes of the bar's chord as pitches inside the register, low to high, across two octaves.
    static func chordTones(_ c: StepContext) -> [Int] {
        // Borrowed and chromatic chords are sung on their in-key tones only: the line never leaves the mode.
        let tones = GenreArrangement.chord(c, degree: c.chord, base: c.keyRoot, seventh: false)
            .filter { c.track.mode.contains(semitones: $0 - c.keyRoot) }
        var out: Set<Int> = []
        for tone in tones {
            let pitchClass = ((tone % 12) + 12) % 12
            var p = low + ((pitchClass - low) % 12 + 12) % 12
            while p <= high {
                out.insert(p)
                p += 12
            }
        }
        return out.sorted()
    }

    /// A scale pitch in the register for a degree relative to the bar's chord root.
    static func scalePitch(_ c: StepContext, degree: Int) -> Int {
        fold(c.track.pitch(60 + ((c.keyRoot % 12) + 12) % 12, degree: c.chord + degree))
    }

    /// The nearest pitch in `pool` to `target` that is not `avoiding`.
    private static func nearest(_ pool: [Int], to target: Int, rng: inout MusicRNG, avoiding: Int? = nil) -> Int {
        let ranked = pool.filter { $0 != avoiding }.sorted { abs($0 - target) < abs($1 - target) }
        guard !ranked.isEmpty else { return target }
        // Mostly the nearest, sometimes the next: the line moves but does not leap.
        return ranked[min(rng.unit() < 0.7 ? 0 : 1, ranked.count - 1)]
    }

    /// One step along the scale from `pitch`, toward `goal`.
    private static func step(_ c: StepContext, from pitch: Int, toward goal: Int) -> Int {
        let scale = Set((-8...14).map { scalePitchRaw(c, degree: $0) })
        let candidates = scale.filter { abs($0 - pitch) <= 2 && $0 != pitch }
        let direction = goal >= pitch ? 1 : -1
        let best = candidates.filter { ($0 - pitch) * direction > 0 }.min { abs($0 - pitch) < abs($1 - pitch) }
        return fold(best ?? pitch + direction)
    }

    private static func scalePitchRaw(_ c: StepContext, degree: Int) -> Int {
        fold(c.track.pitch(60 + ((c.keyRoot % 12) + 12) % 12, degree: degree))
    }

    // MARK: The line

    /// The bar's notes, in order. Strong beats and long notes are chord tones, the notes between them walk the scale
    /// toward the next one, a phrase ends on the root or the fifth, and the bar before a drop swells into it.
    private static func bar(_ c: StepContext, plan: VocalPlan) -> [LineNote] {
        var rng = MusicRNG(
            seed: c.track.seed ^ StableHash.fnv1a("variety/line/\(c.bar / max(c.barsPerPhrase, 1))/\(c.barInPhrase)"))
        let pool = chordTones(c)
        guard pool.count >= 3 else { return [] }
        let drop = c.section == .drop || c.section == .drop2
        let pair = c.barInPhrase % 2
        let hook = c.hook.notes.filter { $0.pos / 16 == pair }
        // The hook's busy bar is the call; the vocal leaves it room and answers in the next. Outside the drops there
        // is no call and the vocal sings the hook's own notes.
        var shape: [(pos: Int, length: Int)]
        if drop {
            if pair == 0 {
                guard hook.count >= 3 else { return [] }
                shape = [(12, 4)]
            } else {
                // The answer: the call's rhythm, shifted two steps, thinned to the notes that last.
                let call = c.hook.notes.filter { $0.pos / 16 == 0 }
                let echoed = call.filter { $0.length >= 2 }.map { (min($0.pos % 16 + 2, 12), min($0.length + 1, 4)) }
                shape = echoed.isEmpty ? [(0, 6), (8, 8)] : Array(echoed.prefix(4))
                if shape.count < 2 { shape.append((8, 8)) }
            }
        } else {
            let sung = hook.filter { $0.length >= 2 }.map { ($0.pos % 16, min($0.length, 8)) }
            shape = sung.isEmpty ? [(0, 8), (8, 8)] : Array(sung.prefix(4))
        }
        shape.sort { $0.pos < $1.pos }
        var seen: Set<Int> = []
        shape = shape.filter { seen.insert($0.pos).inserted }
        guard !shape.isEmpty else { return [] }

        let start = c.barInPhrase == 0 ? (pool.first { $0 >= 69 } ?? pool[0]) : (pool.first { $0 >= 66 } ?? pool[0])
        var previous = nearest(pool, to: start, rng: &rng)
        var out: [LineNote] = []
        for (n, slot) in shape.enumerated() {
            let strong = slot.pos % 8 == 0 || slot.length >= 4
            var pitch: Int
            if strong {
                pitch = nearest(pool, to: previous + (rng.unit() < 0.5 ? 2 : -1), rng: &rng, avoiding: previous)
            } else {
                // A passing note, a step from the last toward the next strong note.
                let goal = shape.dropFirst(n + 1).first { $0.pos % 8 == 0 || $0.length >= 4 }
                let target =
                    goal.map { _ in pool.min { abs($0 - previous - 4) < abs($1 - previous - 4) } ?? previous }
                    ?? previous
                pitch = step(c, from: previous, toward: target)
            }
            out.append(LineNote(pos: slot.pos, length: slot.length, pitch: pitch, strong: strong))
            previous = pitch
        }
        if c.isLastBar, var last = out.popLast() {
            // The phrase comes home: the root or the fifth, held out.
            let home = pool.filter { ($0 - c.track.pitch(60 + ((c.keyRoot % 12) + 12) % 12, degree: 0)) % 12 == 0 }
            let fifth = pool.filter { ($0 - c.track.pitch(60 + ((c.keyRoot % 12) + 12) % 12, degree: 0)) % 12 == 7 }
            let targets = rng.unit() < 0.6 ? (home.isEmpty ? fifth : home) : (fifth.isEmpty ? home : fifth)
            if let landing = targets.min(by: { abs($0 - last.pitch) < abs($1 - last.pitch) }) { last.pitch = landing }
            last.length = max(last.length, min(16 - last.pos, 8))
            last.closing = true
            out.append(last)
        }
        if c.dropComing, c.barInPhrase == c.barsPerPhrase - 1 {
            out = out.filter { $0.pos < 8 }
            if let anchor = out.last?.pitch ?? pool.first {
                out.append(LineNote(pos: 8, length: 8, pitch: anchor, swell: true))
            }
        }
        return out
    }

    /// The vocal line, the stack under it and the effects thrown from it, for this step.
    static func notes(_ c: StepContext, plan: VocalPlan) -> [ScheduledNote] {
        guard plan.line, let pos = c.pos, c.outro != .drumBridge else { return [] }
        var out: [ScheduledNote] = []
        let level = min(1, max(0, c.level))
        let section = c.section
        let drop = section == .drop || section == .drop2

        // Granular pads under the build's first bar of each phrase: the chord, frozen and swelling into the next.
        if section == .build, pos == 0, c.barInPhrase % 2 == 0 {
            let tones = chordTones(c)
            if tones.count >= 3 {
                for (n, pitch) in [tones[1], tones[2]].enumerated() {
                    out.append(
                        sampled(
                            c, pitch: pitch, length: c.perBar * 2, velocity: 0.28 + 0.2 * level,
                            vowel: plan.lineVowel, technique: .vibrato, pan: n == 0 ? -0.4 : 0.4,
                            expression: VocalExpression(
                                vibratoDepth: 0.2, formantShift: -1, stretch: n == 0 ? 3 : 2, swell: 0.8)))
                }
            }
        }

        let line = bar(c, plan: plan).filter { $0.pos == pos }
        for note in line {
            let velocity = (drop ? 0.62 : (section == .build ? 0.5 : (section == .intro ? 0.34 : 0.5))) + 0.18 * level
            let length = c.scaled(note.length)
            var x = expression(c, plan: plan, note: note, drop: drop)
            if note.swell {
                x = VocalExpression(
                    vibratoDepth: 0.15, bend: 3, bendSpan: 1, formantShift: 1, echo: .dottedEighth, echoSend: 0.35,
                    reverse: true, swell: 0.9)
            }
            let lead = sampled(
                c, pitch: note.pitch, length: length, velocity: velocity, vowel: plan.lineVowel,
                technique: drop && plan.character == .power ? .belt : plan.lineTechnique, pan: 0, expression: x,
                delay: c.swing(pos))
            out.append(lead)
            // The stack: thirds, fifths and octaves of the same note, each a little late and a little out of tune.
            if note.length >= 4, plan.harmony > 0, !note.swell, drop || section == .build {
                out += stack(c, plan: plan, note: note, velocity: velocity * 0.55, length: length)
            }
        }

        // A short syllable answer, on the beat: the drop's call-and-response in a chop, not a scatter.
        if plan.chops, drop, c.barInPhrase % 2 == 1, !c.dropComing || pos < 8 {
            if let index = plan.chopGrid.firstIndex(of: pos) {
                let pool = chordTones(c)
                if !pool.isEmpty {
                    let tone = pool[(index * 2 + c.barInPhrase / 2) % pool.count]
                    out.append(
                        ScheduledNote(
                            step: c.step, instrument: .vocalSample, velocity: 0.55 + 0.25 * level,
                            params: NoteParams(
                                pitch: tone, lengthSteps: c.scaled(index == plan.chopGrid.count - 1 ? 3 : 2),
                                formant: plan.chopSlices[index % plan.chopSlices.count], drive: 0.8,
                                voice: NoteParams.sampleVoice(.ah, technique: .straight, kind: .chop),
                                pan: index % 2 == 0 ? -0.3 : 0.3)))
                }
            }
        }
        return out
    }

    private static func sampled(
        _ c: StepContext, pitch: Int, length: Int, velocity: Double, vowel: VocalVowel, technique: SampleTechnique,
        pan: Double, expression: VocalExpression, delay: Double? = nil
    ) -> ScheduledNote {
        // A fold or a step at the register's edge can land off the scale; the voice never leaves the mode.
        var pitch = pitch
        while !c.track.mode.contains(semitones: pitch - c.keyRoot) { pitch -= 1 }
        return ScheduledNote(
            step: c.step, instrument: .vocalSample, velocity: min(1, max(0, velocity)),
            params: NoteParams(
                pitch: pitch, lengthSteps: max(1, length), drive: 0.8,
                voice: NoteParams.sampleVoice(vowel, technique: technique, kind: .sustain), pan: pan, delay: delay
            ).expressed(expression))
    }

    /// How one note of the line is sung.
    private static func expression(_ c: StepContext, plan: VocalPlan, note: LineNote, drop: Bool) -> VocalExpression {
        var x = VocalExpression()
        if note.length >= 4 {
            x.vibratoDepth = 0.45
            x.vibratoRate = 0.45 + 0.2 * plan.lineDraw
        } else {
            x.vibratoDepth = 0.1
        }
        // Phrases lean into their first note and fall off the last.
        if note.pos == 0 || note.strong { x.scoop = note.pos == 0 ? -2 : -1 }
        x.scoopTime = note.pos == 0 ? 0.5 : 0.25
        if note.closing {
            x.bend = -3
            x.bendSpan = 0.3
            x.echo = .dottedEighth
            x.echoSend = 0.45
        }
        if note.length >= 8, !note.closing { x.morph = plan.morphVowel }
        switch plan.character {
        case .natural: break
        case .power:
            x.formantShift = -2
            x.grit = 0.6
            x.breath = 0.2
        case .airy:
            x.formantShift = 2
            x.breath = 0.45
            x.swell = 0.3
        case .robot:
            x.snap = true
            x.formantShift = 2
        }
        // The breakdown goes through a radio, so the drop that follows sounds bigger.
        if c.section == .breakdown, plan.radio { x.filter = .radio }
        return x
    }

    /// Harmony under a note: parallel chord tones above, spread in time, pan, detune and formant.
    private static func stack(
        _ c: StepContext, plan: VocalPlan, note: LineNote, velocity: Double, length: Int
    ) -> [ScheduledNote] {
        let pool = chordTones(c)
        let above = pool.filter { $0 > note.pitch }
        var pitches: [Int] = []
        switch plan.harmony {
        case 1: pitches = Array(above.prefix(2))  // third and fifth
        case 2:  // octave, third
            pitches = [note.pitch + 12 > high ? note.pitch - 12 : note.pitch + 12] + above.prefix(1)
        default:
            pitches = [above.first].compactMap { $0 } + [note.pitch - 12 >= low - 12 ? note.pitch - 12 : note.pitch]
        }
        let spreads: [(delay: Double, pan: Double, detune: Int, formant: Int)] = [
            (0.12, -0.55, -8, -1), (0.22, 0.55, 8, 2), (0.32, 0.0, -4, -2),
        ]
        return pitches.enumerated().map { n, pitch in
            let spread = spreads[n % spreads.count]
            var x = VocalExpression(
                vibratoDepth: 0.4, vibratoRate: 0.4 + 0.12 * Double(n), formantShift: spread.formant,
                detune: spread.detune)
            x.breath = plan.character == .airy ? 0.3 : 0
            return sampled(
                c, pitch: min(max(pitch, low - 12), high + 4), length: length - 1, velocity: velocity,
                vowel: plan.lineVowel, technique: .vibrato, pan: spread.pan, expression: x,
                delay: min(spread.delay + (c.pos.flatMap { c.swing($0) } ?? 0), 0.5))
        }
    }
}

// MARK: - Calls for the drop arranger

/// Vocal gestures an arranger can lay down at a drop (narduk-libs#1641): a riser into it and a stutter across the
/// last beat before it. Both are plain `ScheduledNote`s, so they work from the conductor, from a scenario and from
/// `DropEngine.schedule`.
public enum VocalFX {
    /// A vocal riser that ends on `endStep` (the drop): a held vowel sliding up `rise` semitones across the whole
    /// riser, an octave-up copy sung backwards swelling into the downbeat, both blooming into the room.
    public static func riser(
        endStep: Int, steps: Int = 16, pitch: Int = 67, rise: Int = 7, velocity: Double = 0.7,
        vowel: VocalVowel = .ah
    ) -> [ScheduledNote] {
        let length = max(steps, 4)
        let start = max(endStep - length, 0)
        let base = VocalLine.fold(pitch)
        func note(_ pitch: Int, _ expression: VocalExpression, _ v: Double, pan: Double) -> ScheduledNote {
            ScheduledNote(
                step: start, instrument: .vocalSample, velocity: min(1, max(0, v)),
                params: NoteParams(
                    pitch: pitch, lengthSteps: length, drive: 0.8,
                    voice: NoteParams.sampleVoice(vowel, technique: .vibrato, kind: .sustain), pan: pan
                ).expressed(expression))
        }
        return [
            note(
                base,
                VocalExpression(
                    vibratoDepth: 0.3, scoop: -3, scoopTime: 1, bend: min(max(rise, -8), 7), bendSpan: 1,
                    formantShift: 1, breath: 0.15, swell: 1),
                velocity * 0.9, pan: -0.25),
            note(
                min(base + 12, VocalLine.high + 6),
                VocalExpression(
                    vibratoDepth: 0.2, bend: 4, bendSpan: 1, formantShift: 3, echo: .eighth, echoSend: 0.3,
                    reverse: true, swell: 1),
                velocity * 0.7, pan: 0.25),
        ]
    }

    /// A stutter into the drop at `dropStep`: eighth repeats, then sixteenths, then thirty-seconds across the last
    /// `beats` beats, each cut tighter and brighter than the one before.
    public static func stutterIntoDrop(dropStep: Int, beats: Int = 1, seed: Int = 0) -> [ScheduledNote] {
        let beats = min(max(beats, 1), 4)
        var cuts: [(offset: Int, division: CutDivision, steps: Int, amount: Double)] = []
        if beats >= 2 { cuts.append((8, .eighth, 4, 0.3)) }
        cuts.append((4, .sixteenth, 2, 0.5))
        cuts.append((2, .thirtySecond, 2, 0.9))
        return cuts.enumerated().compactMap { n, cut in
            guard dropStep - cut.offset >= 0 else { return nil }
            return ScheduledNote(
                step: dropStep - cut.offset, instrument: .cut, velocity: 1,
                params: .cut(.stutter, division: cut.division, steps: cut.steps, amount: cut.amount, seed: seed &+ n))
        }
    }
}
