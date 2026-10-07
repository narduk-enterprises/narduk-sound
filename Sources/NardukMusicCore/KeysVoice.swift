import Foundation

/// The `NoteParams.voice` values the `.keys` instrument understands. The conductor writes the first four (any other
/// value below `marimba` or above `sampledConga` plays `voice % 4`; `marimba` ... `sampledConga` are
/// matched exactly); the ambient voices sit well above them so no existing note changes sound. Every voice here is a
/// library voice: any genre, scenario or app may play it.
public enum KeysVoice {
    public static let bell = 0
    public static let stab = 1
    public static let electricPiano = 2
    public static let pad = 3
    /// A woody marimba pluck: a sine bar with its fast-dying fourth-partial overtone and a mallet knock.
    public static let marimba = 4
    /// The pad (voice 3) on a slower sidechain of its own, so it pumps gently with the kick instead of only dipping.
    public static let pumpPad = 5
    /// A breathy pan flute: a soft sine with a little second and third harmonic, a band of breath noise that chiffs at
    /// the onset and stays as air, a slow attack and a delayed, gentle vibrato. Sustains for the note's length.
    public static let panFlute = 6
    /// A steel drum: a bright two-operator strike that settles into the pan's tuned partials (octave and a slightly
    /// sharp twelfth) over an inharmonic ring, decaying like a struck note.
    public static let steelDrum = 7
    /// A sax-like lead: a saw through a breath-opened lowpass and two vowel formants, a soft breathy onset and a delayed
    /// vibrato. Sustains for the note's length.
    public static let saxLead = 8
    /// A warm soft piano: round sine partials with a gentle hammer, a slow 25 ms attack and a long, mellow decay, made
    /// for chords (warmer and longer than `electricPiano`, which has a bright tine and a tremolo).
    public static let softPiano = 9
    /// A recorded grand piano, played softly (Salamander Grand Piano, see `Resources/LICENSES/Instruments.md`). Falls
    /// back to `softPiano` when the instrument bank is missing.
    public static let sampledPiano = 10
    /// A recorded steel pan from Trinidad (jSteelDrum). Falls back to `steelDrum`.
    public static let sampledSteelDrum = 11
    /// A recorded concert flute with vibrato (VSCO 2 Community Edition), held for the note's length. Falls back to
    /// `panFlute`.
    public static let sampledFlute = 12
    /// A recorded alto saxophone with vibrato (University of Iowa), held for the note's length; soft notes play the
    /// pianissimo recording. Falls back to `saxLead`.
    public static let sampledSax = 13
    /// A recorded nylon-string classical guitar, plucked (University of Iowa). Falls back to the acoustic guitar string.
    public static let sampledNylonGuitar = 14
    /// Recorded congas (Versilian Community Sample Library): hand percussion on the keys, so a conga answer can sit in
    /// a phrase. Its pitch picks the drum: below middle C the low conga, from it up the high one. Falls back to the
    /// marimba.
    public static let sampledConga = 15
    /// A slow-attack pad of detuned saws with a moving lowpass; the ambient family's chords (NardukMusicDSP `PadVoice`).
    public static let ambientPad = 100
    /// A very slow, low drone: a detuned fifth-less stack under a sine sub, for the ambient family's bottom.
    public static let drone = 101
}
