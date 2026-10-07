#if canImport(Metal)
    import Foundation
    import Metal
    import NardukMusicCore

    /// What the Metal ports of the Canvas visualizers read beyond the uniforms, the spectrum and the waveform
    /// (buffers 0 ... 2): the peak-hold caps, the pitch classes and key, the pad brightness, the meters, a few triggered
    /// and decimated waveform-history traces, and the piano roll. The renderer fills these from the `SoundVisualState`
    /// into arrays it allocated once, and binds them with `setFragmentBytes` (each under its 4 KB limit), so a frame
    /// allocates nothing. A look that needs none of them (every other Intense kind) binds none.
    struct IntenseAux {
        /// Which of the aux buffers a kind reads.
        struct Needs: OptionSet {
            let rawValue: Int
            /// Buffer 4: `scalarCount` floats (the layout below).
            static let scalars = Needs(rawValue: 1)
            /// Buffer 5: `historyLayers` traces of `historyPoints` floats each, newest first.
            static let history = Needs(rawValue: 2)
            /// Buffers 6 and 7: the piano roll, `rollRows` x `rollColumns` bytes, split at `rollSplit` rows.
            static let roll = Needs(rawValue: 4)
            /// Buffer 8: the particle pool (`particleHeader` + `particleStride` floats a particle).
            static let particles = Needs(rawValue: 8)
        }

        // Layout of buffer 4 (floats).
        static let scalarCount = 128
        /// 0 ..< 64: the peak-hold caps (0 ... 1).
        static let peaks = 0
        /// 64 ..< 76: the pitch classes C ... B (0 ... 1).
        static let pitchClasses = 64
        /// 76 ..< 108: pad brightness by instrument lane (0 ... 1).
        static let pads = 76
        static let padCount = 32
        /// Key tonic (0 = C ... 11 = B, -1 for none), key confidence, 1 when minor, 1 when the roll shows notes.
        static let keyTonic = 108
        static let keyConfidence = 109
        static let keyMinor = 110
        static let rollHasNotes = 111
        /// Peak, RMS and peak-hold meters (0 ... 1), and the analysis chroma flash.
        static let peak = 112
        static let rms = 113
        static let peakHold = 114
        static let chroma = 115
        /// The piano roll's lowest displayed row (a MIDI note) and how many rows it shows.
        static let rollLow = 116
        static let rollSpan = 117
        /// The first rising zero crossing of the live waveform in its leading 128 samples (the scope's trigger).
        static let scopeTrigger = 118
        /// 1 while the source is silent.
        static let silent = 119

        // History traces (buffer 5).
        static let historyLayers = 6
        static let historyPoints = 128
        /// A trace is the 384 samples after the trigger, every third one.
        static let historyStride = 3

        // The roll (buffers 6 and 7): MIDI notes 21 ... 108 (a piano), the newest 64 columns, newest rightmost.
        static let rollLowestNote = 21
        static let rollRows = 88
        static let rollColumns = 64
        static let rollSplit = 44
        static let rollOnset: UInt8 = 255
        static let rollSustain: UInt8 = 140

        private(set) var scalars = [Float](repeating: 0, count: scalarCount)
        private(set) var history = [Float](repeating: 0, count: historyLayers * historyPoints)
        private(set) var rollTop = [UInt8](repeating: 0, count: rollSplit * rollColumns)
        private(set) var rollBottom = [UInt8](repeating: 0, count: (rollRows - rollSplit) * rollColumns)

        // The particle pool (buffer 8, a shared `MTLBuffer` because 320 particles exceed `setFragmentBytes`' 4 KB): a header
        // float4 (live count, build progress), then two float4s a particle: x, y, age, size; vx, vy, tint, kind.
        static let particleFloats = 8
        static let particleBufferCount = 3
        private var particleBuffers: [any MTLBuffer] = []
        private var particleSlot = 0

        init() {}

        /// A set that can also feed the particle field: three rotating buffers, so the GPU never reads one the CPU is
        /// rewriting.
        init(device: any MTLDevice) {
            let length = (1 + 2 * 320) * 16
            particleBuffers = (0..<Self.particleBufferCount).compactMap {
                _ in device.makeBuffer(length: length, options: .storageModeShared)
            }
        }

        /// The first rising zero crossing in the leading 128 samples, so a trace holds still; 0 when there is none.
        static func trigger(_ wave: UnsafeBufferPointer<Float>, base: Int = 0) -> Int {
            guard wave.count >= base + 384 + 128 else { return 0 }
            for i in 1..<128 where wave[base + i - 1] < 0 && wave[base + i] >= 0 { return i }
            return 0
        }

        /// The rows the roll shows: the played range padded by two semitones and at least two octaves, clamped to the
        /// piano. Nil when nothing has been played in the window.
        static func rollWindow(_ range: ClosedRange<Int>?) -> ClosedRange<Int>? {
            guard let range else { return nil }
            let minimum = 24
            var low = range.lowerBound - 2
            var high = range.upperBound + 2
            if high - low + 1 < minimum {
                let extra = minimum - (high - low + 1)
                low -= extra / 2
                high += extra - extra / 2
            }
            let top = rollLowestNote + rollRows - 1
            if low < rollLowestNote {
                high += rollLowestNote - low
                low = rollLowestNote
            }
            if high > top {
                low -= high - top
                high = top
            }
            return max(low, rollLowestNote)...high
        }

        /// Fills what `needs` names from `state`. Touches no heap.
        @MainActor mutating func fill(from state: SoundVisualState, needs: Needs) {
            if needs.contains(.scalars) { fillScalars(state) }
            if needs.contains(.history) { fillHistory(state) }
            if needs.contains(.roll) { fillRoll(state) }
            if needs.contains(.particles) { fillParticles(state) }
        }

        @MainActor private mutating func fillScalars(_ state: SoundVisualState) {
            let musical = state.musical
            let peaks = state.peaks
            let pitchClasses = musical.pitchClasses
            let pads = state.padBrightness
            scalars.withUnsafeMutableBufferPointer { out in
                for i in 0..<SoundVisualState.bandCount { out[Self.peaks + i] = peaks[i] }
                for i in 0..<SoundMusicalState.pitchClassCount { out[Self.pitchClasses + i] = pitchClasses[i] }
                for i in 0..<min(Self.padCount, pads.count) { out[Self.pads + i] = pads[i] }
                out[Self.keyTonic] = Float(musical.keyPitchClass ?? -1)
                out[Self.keyConfidence] = musical.keyConfidence
                out[Self.keyMinor] = musical.keyIsMinor ? 1 : 0
                out[Self.rollHasNotes] = musical.noteRange == nil ? 0 : 1
                out[Self.peak] = Float(state.peak)
                out[Self.rms] = Float(state.rms)
                out[Self.peakHold] = Float(state.peakHold)
                out[Self.chroma] = state.chroma
                let window = Self.rollWindow(musical.noteRange)
                out[Self.rollLow] = Float(window?.lowerBound ?? Self.rollLowestNote)
                out[Self.rollSpan] = Float(window?.count ?? SoundMusicalState.pitchClassCount)
                out[Self.scopeTrigger] = Float(Self.trigger(state.waveform))
                out[Self.silent] = state.isSilent ? 1 : 0
            }
        }

        @MainActor private mutating func fillParticles(_ state: SoundVisualState) {
            guard !particleBuffers.isEmpty else { return }
            particleSlot = (particleSlot + 1) % particleBuffers.count
            let buffer = particleBuffers[particleSlot]
            let capacity = buffer.length / 16 / 2 - 1
            let out = buffer.contents().assumingMemoryBound(to: Float.self)
            let pool = state.particles
            let count = min(pool.count, capacity)
            out[0] = Float(count)
            out[1] = state.section == .build ? state.phraseProgress : 0
            out[2] = 0
            out[3] = 0
            for i in 0..<count {
                let particle = pool[i]
                let base = 4 + i * Self.particleFloats
                let live = particle.life > 0
                out[base] = particle.x
                out[base + 1] = particle.y
                out[base + 2] = live ? particle.age : 1
                out[base + 3] = particle.size
                out[base + 4] = particle.vx
                out[base + 5] = particle.vy
                out[base + 6] = particle.tint - particle.tint.rounded(.down)
                out[base + 7] = Float(particle.kind.rawValue)
            }
        }

        @MainActor private mutating func fillHistory(_ state: SoundVisualState) {
            let source = state.history
            let depth = SoundVisualState.historyDepth
            let samples = SoundVisualState.sampleCount
            let valid = state.historyCount
            let head = state.historyHead
            history.withUnsafeMutableBufferPointer { out in
                for age in 0..<Self.historyLayers {
                    let base = age * Self.historyPoints
                    guard age < valid else {
                        for k in 0..<Self.historyPoints { out[base + k] = 0 }
                        continue
                    }
                    let slot = ((head - age) % depth + depth) % depth
                    let start = slot * samples
                    let first = Self.trigger(source, base: start)
                    for k in 0..<Self.historyPoints { out[base + k] = source[start + first + Self.historyStride * k] }
                }
            }
        }

        @MainActor private mutating func fillRoll(_ state: SoundVisualState) {
            let musical = state.musical
            let notes = SoundMusicalState.noteCount
            let columns = Self.rollColumns
            let cells = musical.roll
            let chroma = musical.chromaRoll
            let chromaRows = SoundMusicalState.pitchClassCount
            let showsNotes = musical.noteRange != nil
            let split = Self.rollSplit
            let count = min(musical.rollCount, columns)
            rollTop.withUnsafeMutableBufferPointer { top in
                rollBottom.withUnsafeMutableBufferPointer { bottom in
                    for row in 0..<Self.rollRows {
                        for slot in 0..<columns {
                            let age = columns - 1 - slot
                            var value: UInt8 = 0
                            if age < count, let column = musical.column(age: age) {
                                if showsNotes {
                                    let note = Self.rollLowestNote + row
                                    let level = cells[column * notes + note]
                                    if level >= SoundMusicalState.onsetLevel {
                                        value = Self.rollOnset
                                    } else if level > 0 {
                                        value = Self.rollSustain
                                    }
                                } else if row < chromaRows {
                                    value = UInt8(min(max(chroma[column * chromaRows + row], 0), 1) * 255)
                                }
                            }
                            if row < split {
                                top[row * columns + slot] = value
                            } else {
                                bottom[(row - split) * columns + slot] = value
                            }
                        }
                    }
                }
            }
        }

        /// Binds what `needs` names to `encoder`.
        func bind(_ needs: Needs, to encoder: any MTLRenderCommandEncoder) {
            if needs.contains(.scalars) { Self.set(scalars, on: encoder, index: 4) }
            if needs.contains(.history) { Self.set(history, on: encoder, index: 5) }
            if needs.contains(.roll) {
                Self.set(rollTop, on: encoder, index: 6)
                Self.set(rollBottom, on: encoder, index: 7)
            }
            if needs.contains(.particles), !particleBuffers.isEmpty {
                encoder.setFragmentBuffer(particleBuffers[particleSlot], offset: 0, index: 8)
            }
        }

        private static func set<T>(_ array: [T], on encoder: any MTLRenderCommandEncoder, index: Int) {
            array.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress { encoder.setFragmentBytes(base, length: bytes.count, index: index) }
            }
        }
    }

    extension IntenseKind {
        /// The aux buffers this kind reads (none for the original looks).
        var auxNeeds: IntenseAux.Needs { IntenseAux.Needs(rawValue: auxMask) }
    }
#endif
