import Foundation
import NardukMusicCore

/// The trivially copyable form of a `ScheduledNote` that crosses the lock-free ring
/// into the render thread. Optional parameters are encoded as negative sentinels.
public struct SynthEvent: Sendable, Hashable, BitwiseCopyable {
    public var step: Int
    public var instrument: UInt8
    public var velocity: Float
    public var pitch: Float  // MIDI, < 0 when absent
    public var lengthSteps: Int32
    public var cyclesPerBeat: Float  // <= 0 when absent
    public var formant: Float  // < 0 when absent
    public var drive: Float  // < 0 when absent
    public var voice: Int32  // < 0 when absent
    public var pan: Float
    public var glide: Float  // < 0 when absent
    public var delay: Float  // 0 ... 0.5 of a step late

    public init(_ note: ScheduledNote) {
        step = note.step
        instrument = note.instrument.synthCode
        velocity = Float(min(max(note.velocity.isFinite ? note.velocity : 0, 0), 1))
        pitch = note.params.pitch.map { Float(min(max($0, 0), 127)) } ?? -1
        lengthSteps = Int32(min(max(note.params.lengthSteps, 1), 256))
        cyclesPerBeat = note.params.wobbleRate.map { Float($0.cyclesPerBeat) } ?? 0
        formant = note.params.formant.map { Float(min(max($0.isFinite ? $0 : 0.5, 0), 1)) } ?? -1
        drive = note.params.drive.map { Float(min(max($0.isFinite ? $0 : 0.5, 0), 1)) } ?? -1
        voice = note.params.voice.map { Int32(truncatingIfNeeded: $0 & 0x7FFF_FFFF) } ?? -1
        pan = Float(min(max(note.params.pan.isFinite ? note.params.pan : 0, -1), 1))
        glide = note.params.glide.map { Float(min(max($0.isFinite ? $0 : 0, 0), 1)) } ?? -1
        delay = note.params.delay.map { Float(min(max($0.isFinite ? $0 : 0, 0), 0.5)) } ?? 0
    }
}

extension Instrument {
    /// A stable small integer for the render thread and the hits bitmask.
    public var synthCode: UInt8 {
        switch self {
        case .kick: 0
        case .snare: 1
        case .hat: 2
        case .openHat: 3
        case .wobble: 4
        case .sub: 5
        case .glitch: 6
        case .scratch: 7
        case .laser: 8
        case .vox: 9
        case .riser: 10
        case .tapeStop: 11
        case .impact: 12
        case .keys: 13
        }
    }

    public init?(synthCode: UInt8) {
        guard let match = Instrument.allCases.first(where: { $0.synthCode == synthCode }) else { return nil }
        self = match
    }

    /// Decodes a hits bitmask (bit n = synthCode n).
    public static func set(fromMask mask: UInt32) -> Set<Instrument> {
        var result = Set<Instrument>()
        for instrument in Instrument.allCases where mask & (1 << UInt32(instrument.synthCode)) != 0 {
            result.insert(instrument)
        }
        return result
    }
}
