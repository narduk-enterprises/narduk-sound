import Foundation

/// The `NoteParams.voice` values the `.keys` instrument understands. The conductor writes the first four (any other
/// value plays `voice % 4`, except `marimba` and `pumpPad`, which are matched exactly); the ambient voices sit well
/// above them so no existing note changes sound.
public enum KeysVoice {
    public static let bell = 0
    public static let stab = 1
    public static let electricPiano = 2
    public static let pad = 3
    /// A woody marimba pluck: a sine bar with its fast-dying fourth-partial overtone and a mallet knock (tropical house).
    public static let marimba = 4
    /// The pad (voice 3) on a slower sidechain of its own, so it pumps with the kick instead of only dipping.
    public static let pumpPad = 5
    /// A slow-attack pad of detuned saws with a moving lowpass; the ambient family's chords (NardukMusicDSP `PadVoice`).
    public static let ambientPad = 100
    /// A very slow, low drone: a detuned fifth-less stack under a sine sub, for the ambient family's bottom.
    public static let drone = 101
}
