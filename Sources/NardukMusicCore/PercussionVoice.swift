import Foundation

/// `NoteParams.voice` values the drum instruments understand: a recorded hand percussion sound in place of the synth
/// drum. Any other value (or none) plays the synth drum, so no existing note changes sound. Each falls back to the
/// synth drum when the instrument bank is missing. Library voices: any genre, scenario or app may play them.
public enum PercussionVoice {
    /// On `.snare`: a recorded finger snap (Freesound, CC0).
    public static let snap = 1
    /// On `.hat`: a recorded small shaker, its strokes taking turns (Versilian Community Sample Library, CC0).
    public static let shaker = 2
    /// On `.openHat`: a recorded tambourine, shaken when soft and struck when loud (VCSL, CC0).
    public static let tambourine = 3
}
