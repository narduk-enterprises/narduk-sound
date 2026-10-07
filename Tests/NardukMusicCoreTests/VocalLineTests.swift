import Testing

@testable import NardukMusicCore

/// The sampled voice singing from the song's own chords and hook (narduk-libs#1641).
@Suite struct VocalLineTests {
    static func play(_ genre: Genre, variety: Double, seed: UInt64, bars: Int = 96) -> (
        notes: [ScheduledNote], track: Track
    ) {
        VocalArrangementTests.play(genre, variety: variety, seed: seed, bars: bars)
    }

    /// Every note with the track that wrote it (a long run changes track).
    static func playTracked(_ genre: Genre, variety: Double, seed: UInt64, bars: Int = 96) -> [(
        note: ScheduledNote, track: Track
    )] {
        var conductor = DropConductor(settings: SongSettings.varied(genre: genre, seed: seed, variety: variety))
        var out: [(ScheduledNote, Track)] = []
        for step in 0..<(bars * 16) {
            let phase = (step / 16) % 32
            conductor.ingest(MusicSignal(level: phase < 6 ? 0.1 : (phase < 12 ? 0.6 : 0.95), levelLabel: "CPU"))
            let notes = conductor.advance(throughStep: step)
            let track = conductor.track  // the track that wrote them: it can change as the step is advanced
            out += notes.map { ($0, track) }
        }
        return out
    }

    /// The lead's notes: a sustain that is not a stack voice (stacks are detuned), a swell or a frozen pad.
    static func leads(_ notes: [ScheduledNote]) -> [ScheduledNote] {
        notes.filter {
            guard $0.instrument == .vocalSample, SampleKind(voice: $0.params.voice ?? 0) == .sustain else {
                return false
            }
            let x = VocalExpression(packed: $0.params.expression ?? 0)
            return x.detune == 0 && x.stretch == 0 && !x.reverse
        }
    }

    static let electronic: [Genre] = [.chill, .house, .synthwave, .dubstep, .trap, .ukGarage, .techno, .lofi]

    @Test func theLineIsOnlyThereBehindVariety() {
        for genre in Genre.allCases {
            let (notes, track) = Self.play(genre, variety: 0, seed: 21)
            #expect(track.vocals == nil)
            #expect(notes.allSatisfy { $0.instrument != .vocalSample }, "\(genre)")
        }
    }

    @Test func theSongSingsWhereTheLineIsDrawn() {
        var singers = 0
        for genre in Self.electronic {
            for seed: UInt64 in 1...8 {
                let (notes, track) = Self.play(genre, variety: 1, seed: seed)
                if track.vocals?.line == true {
                    singers += 1
                    #expect(Self.leads(notes).count > 8, "\(genre) \(seed)")
                }
            }
        }
        #expect(singers >= 40)
    }

    @Test func theLineIsInKeyAndInRegister() {
        // Chords borrowed from outside the mode are sung on their in-mode tones only: the line never leaves the key.
        var total = 0
        var outside = 0
        for genre in Self.electronic {
            for seed: UInt64 in 1...6 {
                for (note, track) in Self.playTracked(genre, variety: 1, seed: seed)
                where note.instrument == .vocalSample && track.vocals?.line == true {
                    guard let pitch = note.params.pitch else { continue }
                    total += 1
                    if !track.mode.contains(semitones: pitch - track.keyRoot) { outside += 1 }
                    #expect(pitch >= VocalLine.low - 12 && pitch <= VocalLine.high + 12, "\(genre) \(seed) \(pitch)")
                }
            }
        }
        #expect(total > 500)
        #expect(outside == 0, "\(outside) of \(total) notes outside the scale")
    }

    @Test func strongBeatsLandOnChordTones() {
        var strong = 0
        var onChord = 0
        for genre in [Genre.chill, .house, .synthwave, .techno] {
            for seed: UInt64 in 1...6 {
                for (note, track) in Self.playTracked(genre, variety: 1, seed: seed)
                where track.vocals?.line == true && Self.leads([note]).count == 1 {
                    guard let pitch = note.params.pitch, note.step % 8 == 0 else { continue }
                    let bar = note.step / 16
                    let triad = Set(
                        [0, 2, 4].map {
                            (track.keyRoot + track.mode.semitones(track.chord(bar % 8) + $0)) % 12
                        })
                    strong += 1
                    if triad.contains(((pitch % 12) + 12) % 12) { onChord += 1 }
                }
            }
        }
        #expect(strong > 40)
        #expect(Double(onChord) / Double(max(strong, 1)) > 0.8, "\(onChord) of \(strong)")
    }

    @Test func theLineIsDeterministicAndDiffersBySeed() {
        let a = Self.play(.house, variety: 1, seed: 5)
        let b = Self.play(.house, variety: 1, seed: 5)
        #expect(a.notes == b.notes)
        var seen: Set<[Int]> = []
        for seed: UInt64 in 1...12 {
            let (notes, track) = Self.play(.house, variety: 1, seed: seed)
            guard track.vocals?.line == true else { continue }
            seen.insert(Self.leads(notes).prefix(16).compactMap { $0.params.pitch })
        }
        #expect(seen.count >= 6, "twelve seeds sang \(seen.count) different lines")
    }

    @Test func theChopsAreFewAndOnTheGrid() {
        for seed: UInt64 in 1...10 {
            // The first track only: a long run changes track, and with it the chop grid.
            let played = Self.playTracked(.dubstep, variety: 1, seed: seed, bars: 40)
            guard let plan = played.first?.track.vocals, plan.chops else { continue }
            let chops = played.filter {
                $0.track.seed == played[0].track.seed && $0.note.instrument == .vocalSample
                    && SampleKind(voice: $0.note.params.voice ?? 0) == .chop
            }.map(\.note)
            let allowed = Set(plan.chopGrid)
            #expect(chops.allSatisfy { allowed.contains($0.step % 16) })
            // A few a bar, and the same slice on the same beat each time.
            var slices: [Int: Set<Double>] = [:]
            for chop in chops { slices[chop.step % 16, default: []].insert(chop.params.formant ?? 0) }
            #expect(slices.values.allSatisfy { $0.count == 1 })
            let perBar = Dictionary(grouping: chops, by: { $0.step / 16 }).values.map(\.count).max() ?? 0
            #expect(perBar <= 3)
        }
    }

    @Test func theStackSitsUnderTheLeadWithSpread() {
        var checked = 0
        for seed: UInt64 in 1...10 {
            let (notes, track) = Self.play(.house, variety: 1, seed: seed)
            guard let plan = track.vocals, plan.line, plan.harmony > 0 else { continue }
            let stack = notes.filter {
                $0.instrument == .vocalSample && VocalExpression(packed: $0.params.expression ?? 0).detune != 0
            }
            guard !stack.isEmpty else { continue }
            checked += 1
            #expect(stack.allSatisfy { ($0.params.delay ?? 0) > 0.05 }, "a choir from one singer is a little late")
            #expect(Set(stack.map(\.params.pan)).count >= 2)
        }
        #expect(checked > 0)
    }

    @Test func riserAndStutterAreCallableFromAnArranger() {
        let riser = VocalFX.riser(endStep: 64, steps: 16)
        #expect(riser.allSatisfy { $0.instrument == .vocalSample && $0.step == 48 && $0.params.lengthSteps == 16 })
        #expect(riser.contains { VocalExpression(packed: $0.params.expression ?? 0).reverse })
        let stutter = VocalFX.stutterIntoDrop(dropStep: 64, beats: 2)
        #expect(stutter.map(\.step) == [56, 60, 62])
        #expect(stutter.allSatisfy { $0.instrument == .cut })
        #expect(VocalFX.stutterIntoDrop(dropStep: 3).allSatisfy { $0.step >= 0 })
    }

    @Test func expressionPacksAndUnpacks() {
        #expect(VocalExpression().packed == 0)
        #expect(VocalExpression(packed: 0) == VocalExpression())
        for preset in [
            VocalExpression.torch, .power, .robot, .telephone, .morphing, .frozen,
            VocalExpression(scoop: -7, bend: 5, bendSpan: 1, detune: -28, echo: .quarter, echoSend: 1, reverse: true),
        ] {
            let back = VocalExpression(packed: preset.packed)
            #expect(back.packed == preset.packed)
            #expect(back.scoop == preset.scoop && back.bend == preset.bend && back.morph == preset.morph)
            #expect(back.formantShift == preset.formantShift && back.snap == preset.snap)
            #expect(back.detune == preset.detune && back.echo == preset.echo && back.filter == preset.filter)
            #expect(back.stretch == preset.stretch && back.reverse == preset.reverse)
        }
        #expect(VocalExpression.torch.packed != VocalExpression.power.packed)
    }
}
