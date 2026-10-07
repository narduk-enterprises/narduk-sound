// The ambient family's arrangement: no drums, no risers, no drops. The five song sections are reused with a different
// meaning (narduk-libs#1576, Logan's choice): the signal level moves the music up and down in swells and settles
// instead of building and dropping.
//
//   intro      stillness  a drone under a thin, quiet pad
//   build      swell      pads join every bar and open across the phrase, as far as the level allows
//   drop       bloom      the full chord, an octave of air above it, sparse plucked guitar when the level is up
//   breakdown  settle     the drone alone, a quiet pad now and then
//   drop2      radiance   a bloom that lasts (the same arrangement as bloom, one step brighter)
//
// Every dynamic is a function of the signal level (`StepContext.level`) and the bar, never of a random draw, so the
// arrangement adds nothing to the conductor's random sequence and an electronic song is untouched.

extension SongSection {
    /// The name a section goes by in a family: electronic songs say intro, build, drop; ambient ones say how the
    /// music moves.
    public func label(in family: GenreFamily) -> String {
        guard family == .ambient else { return rawValue }
        switch self {
        case .intro: return "stillness"
        case .build: return "swell"
        case .drop: return "bloom"
        case .breakdown: return "settle"
        case .drop2: return "radiance"
        }
    }
}

enum AmbientArrangement {
    /// A chord that sounds for `bars` bars: pad notes overlap the next chord a little so the change blooms in.
    private static func padLength(_ c: StepContext, bars: Int) -> Int { c.perBar * bars + c.perBar / 2 }

    static func notes(_ c: StepContext) -> [ScheduledNote] {
        // Chords change on bar lines; everything below starts there or on a beat inside the bar.
        guard let pos = c.pos else { return [] }
        let level = min(1, max(0, c.level))
        let bar = c.barInPhrase
        let phraseProgress = Double(bar) / Double(max(1, c.barsPerPhrase - 1))
        var out: [ScheduledNote] = []

        func add(
            _ instrument: Instrument, _ velocity: Double, pitch: Int, length: Int, voice: Int? = nil
        ) {
            out.append(
                ScheduledNote(
                    step: c.step, instrument: instrument, velocity: min(1, max(0, velocity)),
                    params: NoteParams(pitch: pitch, lengthSteps: length, voice: voice)))
        }

        let tones = GenreArrangement.chord(c, degree: c.chord, base: c.keyRoot - 12, seventh: true)
        let thirdAndFifth = Array(tones.prefix(3))

        if pos == 0 {
            // The drone moves with the progression, four bars at a time, and is never silent.
            if bar % 4 == 0 {
                let droneVelocity: Double =
                    switch c.section {
                    case .intro: 0.45 + 0.3 * level
                    case .build: 0.5 + 0.3 * level
                    case .drop, .drop2: 0.55 + 0.25 * level
                    case .breakdown: 0.6 + 0.25 * level
                    }
                add(
                    .keys, droneVelocity, pitch: c.track.pitch(c.keyRoot - 36, degree: c.chord),
                    length: padLength(c, bars: 4), voice: KeysVoice.drone)
            }

            switch c.section {
            case .intro:
                // Stillness: two chord tones every other bar, as loud as the room is.
                if bar % 2 == 0 {
                    for pitch in thirdAndFifth.prefix(2) {
                        add(
                            .keys, 0.2 + 0.25 * level, pitch: pitch, length: padLength(c, bars: 2),
                            voice: KeysVoice.ambientPad)
                    }
                }
            case .build:
                // Swell: a chord every bar that grows across the phrase, further the higher the level.
                let swell = 0.25 + 0.5 * phraseProgress * (0.4 + 0.6 * level)
                for pitch in tones {
                    add(.keys, swell, pitch: pitch, length: padLength(c, bars: 1), voice: KeysVoice.ambientPad)
                }
            case .drop, .drop2:
                // Bloom: the whole chord and its octave, held two bars.
                if bar % 2 == 0 {
                    let bloom = (c.section == .drop2 ? 0.6 : 0.5) + 0.3 * level
                    for pitch in tones {
                        add(.keys, bloom, pitch: pitch, length: padLength(c, bars: 2), voice: KeysVoice.ambientPad)
                    }
                    add(
                        .keys, bloom * 0.6, pitch: tones[0] + 12, length: padLength(c, bars: 2),
                        voice: KeysVoice.ambientPad)
                }
            case .breakdown:
                // Settle: a quiet pad every fourth bar, the drone carries the rest.
                if bar % 4 == 2 {
                    for pitch in thirdAndFifth.prefix(2) {
                        add(
                            .keys, 0.16 + 0.2 * level, pitch: pitch, length: padLength(c, bars: 2),
                            voice: KeysVoice.ambientPad)
                    }
                }
            }
        }

        // Sparse plucked guitar over a bloom, only once the signal is up: one note a bar, walking the chord.
        if c.section == .drop || c.section == .drop2, level > 0.25, pos == (bar % 2 == 0 ? 6 : 10) {
            let pitch = tones[(bar + c.chord) % tones.count] + 24
            add(.acousticGuitar, 0.25 + 0.3 * level, pitch: pitch, length: c.scaled(10))
        }
        return out
    }
}
