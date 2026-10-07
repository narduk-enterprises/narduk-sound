import Foundation
import NardukMusicCore
import Testing

@testable import NardukMusicDSP

/// The ambient chain: a long reverb, a delay line, and the pad / drone voice (keys voices 100 and 101).
/// Set `NARDUK_AMBIENT_DEMO_DIR` to a directory to also write a listenable demo (`ambient-demo.wav`).
@Suite(.serialized) struct AmbientTests {
    static let sampleRate = 48_000.0

    #if arch(arm64) && canImport(Darwin)
        static let platform = "darwin-arm64"
    #else
        static let platform = "linux-x86_64"
    #endif

    // MARK: Helpers

    /// FNV-1a 64 over the sample bits, left then right (the same scheme as the offline renderer's fingerprint).
    static func fingerprint(_ left: [Float], _ right: [Float]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for channel in [left, right] {
            for sample in channel {
                var bits = sample.bitPattern
                for _ in 0..<4 {
                    hash = (hash ^ UInt64(bits & 0xff)) &* 0x100_0000_01b3
                    bits >>= 8
                }
            }
        }
        return hash
    }

    static func rms(_ samples: [Float], _ range: Range<Int>) -> Float {
        var sum: Float = 0
        for n in range { sum += samples[n] * samples[n] }
        return (sum / Float(range.count)).squareRoot()
    }

    static func hallResponse(decay: Float, seconds: Double) -> ([Float], [Float]) {
        var hall = HallReverb(sampleRate: sampleRate, decaySeconds: decay)
        defer { hall.deallocate() }
        var left: [Float] = []
        var right: [Float] = []
        for n in 0..<Int(seconds * sampleRate) {
            let out = hall.process(n == 0 ? 1 : 0, n == 0 ? 1 : 0)
            left.append(out.0)
            right.append(out.1)
        }
        return (left, right)
    }

    static func echoes(pingPong: Bool, feedback: Float) -> ([Float], [Float]) {
        var delay = StereoDelay(sampleRate: sampleRate, seconds: 0.1)
        defer { delay.deallocate() }
        delay.pingPong = pingPong
        delay.feedback = feedback
        var left: [Float] = []
        var right: [Float] = []
        for n in 0..<Int(sampleRate) {
            let out = delay.process(n == 0 ? 1 : 0, 0)
            left.append(out.0)
            right.append(out.1)
        }
        return (left, right)
    }

    static func peak(_ samples: [Float], near center: Int, radius: Int = 40) -> (index: Int, value: Float) {
        var best = (index: center, value: Float(0))
        for n in max(0, center - radius)...min(samples.count - 1, center + radius) where abs(samples[n]) > best.value {
            best = (n, abs(samples[n]))
        }
        return best
    }

    /// An ambient scene through the real synth core: a held pad chord over a drone, 24 s at 60 bpm.
    static func renderScene(seconds: Double = 24) -> ([Float], [Float]) {
        let core = DropSynthCore(sampleRate: sampleRate, bpm: 60)
        let frames = 512
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer {
            left.deallocate()
            right.deallocate()
        }
        let chord: [(step: Int, pitch: Int, voice: Int, length: Int, velocity: Double)] = [
            (0, 33, KeysVoice.drone, 56, 0.7),
            (0, 57, KeysVoice.ambientPad, 28, 0.7), (0, 60, KeysVoice.ambientPad, 28, 0.6),
            (0, 64, KeysVoice.ambientPad, 28, 0.6),
            (32, 53, KeysVoice.ambientPad, 28, 0.7), (32, 57, KeysVoice.ambientPad, 28, 0.6),
            (32, 60, KeysVoice.ambientPad, 28, 0.6),
        ]
        for note in chord {
            core.schedule(
                ScheduledNote(
                    step: note.step, instrument: .keys, velocity: note.velocity,
                    params: NoteParams(pitch: note.pitch, lengthSteps: note.length, voice: note.voice)))
        }
        var outLeft: [Float] = []
        var outRight: [Float] = []
        var rendered = 0
        let total = Int(seconds * sampleRate)
        while rendered < total {
            core.render(frames: frames, left: left, right: right)
            outLeft.append(contentsOf: UnsafeBufferPointer(start: left, count: frames))
            outRight.append(contentsOf: UnsafeBufferPointer(start: right, count: frames))
            rendered += frames
        }
        return (outLeft, outRight)
    }

    static func writeWAV(_ left: [Float], _ right: [Float], to url: URL) throws {
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let frames = left.count
        data.append(contentsOf: Array("RIFF".utf8))
        put(UInt32(36 + frames * 4))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        put(UInt32(16))
        put(UInt16(1))
        put(UInt16(2))
        put(UInt32(sampleRate))
        put(UInt32(sampleRate) * 4)
        put(UInt16(4))
        put(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        put(UInt32(frames * 4))
        for n in 0..<frames {
            put(Int16(max(-1, min(1, left[n])) * 32_767))
            put(Int16(max(-1, min(1, right[n])) * 32_767))
        }
        try data.write(to: url)
    }

    func expectGolden(_ left: [Float], _ right: [Float], darwin: UInt64, linux: UInt64) {
        let golden = Self.platform == "darwin-arm64" ? darwin : linux
        let actual = String(format: "0x%016llx", Self.fingerprint(left, right))
        #expect(Self.fingerprint(left, right) == golden, "\(Self.platform) fingerprint \(actual)")
    }

    // MARK: Hall reverb

    @Test func hallTailFollowsItsDecayTime() {
        let short = Self.hallResponse(decay: 4, seconds: 12)
        let long = Self.hallResponse(decay: 12, seconds: 12)
        let rate = Int(Self.sampleRate)
        for response in [short, long] { #expect(response.0.allSatisfy { $0.isFinite }) }
        // RT60 is the time to fall 60 dB, so over 3 s a 4 s tail falls ~45 dB and a 12 s tail ~15 dB.
        func fall(_ response: ([Float], [Float])) -> Float {
            20 * log10f(Self.rms(response.0, 4 * rate..<5 * rate) / Self.rms(response.0, 1 * rate..<2 * rate))
        }
        #expect((-60)...(-25) ~= fall(short), "4 s tail fell \(fall(short)) dB")
        #expect((-30)...(-5) ~= fall(long), "12 s tail fell \(fall(long)) dB")
        #expect(fall(long) > fall(short) + 10)
    }

    @Test func hallIsStereoAndStableAtTheLongestDecay() {
        let response = Self.hallResponse(decay: HallReverb.maxDecaySeconds, seconds: 20)
        let peak = response.0.map(abs).max() ?? 0
        #expect(response.0.allSatisfy { $0.isFinite } && response.1.allSatisfy { $0.isFinite })
        #expect(peak < 1, "the tail rang above the input: \(peak)")
        #expect(response.0 != response.1, "the two sides must decorrelate")
    }

    @Test func hallDecayChangeIsANoOpWhenUnchanged() {
        var hall = HallReverb(sampleRate: Self.sampleRate, decaySeconds: 6)
        defer { hall.deallocate() }
        hall.setDecayIfChanged(6)
        #expect(hall.decaySeconds == 6)
        hall.setDecayIfChanged(99)
        #expect(hall.decaySeconds == HallReverb.maxDecaySeconds)
        hall.setDecayIfChanged(.nan)
        #expect(hall.decaySeconds.isFinite)
    }

    // MARK: Delay

    @Test func delayEchoesLandOnTheTimeAndDecayByTheFeedback() {
        let response = Self.echoes(pingPong: false, feedback: 0.5)
        let first = Self.peak(response.0, near: 4_800)
        let second = Self.peak(response.0, near: 9_600, radius: 60)
        #expect(first.value > 0.3, "first echo \(first.value) at \(first.index)")
        #expect(abs(first.index - 4_800) <= 40)
        // The feedback lowpass smears the second echo, so it is quieter than the plain feedback ratio.
        #expect(second.value < first.value * 0.6 && second.value > first.value * 0.05, "second echo \(second.value)")
        #expect(
            (response.1.map(abs).max() ?? 0) < 1e-6,
            "a left-only input stays left without ping-pong: \(response.1.map(abs).max() ?? 0)")
    }

    @Test func delayPingPongAlternatesSides() {
        let response = Self.echoes(pingPong: true, feedback: 0.6)
        #expect(Self.peak(response.0, near: 4_800).value > 0.3)
        #expect(Self.peak(response.1, near: 4_800).value < 0.05)
        #expect(Self.peak(response.1, near: 9_600, radius: 80).value > 0.1)
        #expect(Self.peak(response.0, near: 9_600, radius: 80).value < 0.05)
    }

    @Test func delayFeedbackIsClampedBelowRunaway() {
        var delay = StereoDelay(sampleRate: Self.sampleRate, seconds: 0.05)
        defer { delay.deallocate() }
        delay.feedback = 5
        #expect(delay.feedback <= 0.95)
        var peak: Float = 0
        for n in 0..<Int(Self.sampleRate * 20) {
            let out = delay.process(n == 0 ? 1 : 0, 0)
            peak = max(peak, abs(out.0), abs(out.1))
        }
        #expect(peak.isFinite && peak <= 1)
    }

    @Test func delayTimeChangeGlidesWithoutAClick() {
        var delay = StereoDelay(sampleRate: Self.sampleRate, seconds: 0.2)
        defer { delay.deallocate() }
        delay.feedback = 0.4
        var previous: Float = 0
        var biggestStep: Float = 0
        for n in 0..<Int(Self.sampleRate * 3) {
            if n == Int(Self.sampleRate) { delay.setTime(steps: 6, bpm: 90, sampleRate: Self.sampleRate) }
            let input = 0.5 * sinf(DSP.twoPi * 220 * Float(n) / Float(Self.sampleRate))
            let out = delay.process(input, input).0
            if n > 10 { biggestStep = max(biggestStep, abs(out - previous)) }
            previous = out
        }
        #expect(biggestStep < 0.08, "a time change clicked: a \(biggestStep) sample step")
        #expect(abs(delay.samples - Float(6 * 60 / 90.0 / 4 * Self.sampleRate)) < 100, "glided to \(delay.samples)")
    }

    // MARK: Pad and drone

    @Test func padSwellsInSmoothlyAndReleasesToSilence() {
        let c = SynthCoefficients(sampleRate: Self.sampleRate)
        var pad = PadVoice()
        pad.noteOn(.pad, pitch: 57, gateSamples: Int(4 * Self.sampleRate), velocity: 0.8, c)
        var left: [Float] = []
        for _ in 0..<Int(14 * Self.sampleRate) { left.append(pad.next(c).0) }
        let rate = Int(Self.sampleRate)
        #expect(left.allSatisfy { $0.isFinite })
        #expect(Self.rms(left, 0..<rate / 10) < 0.01, "a pad must not start at full level")
        #expect(Self.rms(left, 3 * rate..<4 * rate) > 0.02)
        #expect(Self.rms(left, 3 * rate..<4 * rate) > Self.rms(left, 0..<rate / 2) * 3)
        #expect(Self.rms(left, 13 * rate..<14 * rate) < 1e-4, "a released pad must fade to silence")
        let biggestStep = zip(left.dropFirst(), left).map { abs($0 - $1) }.max() ?? 0
        #expect(biggestStep < 0.05, "the pad clicked: a \(biggestStep) sample step")
    }

    @Test func droneIsLowerAndSlowerThanThePad() {
        let c = SynthCoefficients(sampleRate: Self.sampleRate)
        var pad = PadVoice()
        var drone = PadVoice()
        pad.noteOn(.pad, pitch: 57, gateSamples: Int(6 * Self.sampleRate), velocity: 0.8, c)
        drone.noteOn(.drone, pitch: 33, gateSamples: Int(6 * Self.sampleRate), velocity: 0.8, c)
        var padOut: [Float] = []
        var droneOut: [Float] = []
        for _ in 0..<Int(2 * Self.sampleRate) {
            padOut.append(pad.next(c).0)
            droneOut.append(drone.next(c).0)
        }
        #expect(Self.rms(droneOut, 0..<padOut.count) < Self.rms(padOut, 0..<padOut.count), "the drone swells slower")
        #expect(PadVoice.releaseSamples(.drone, sampleRate: 48_000) > PadVoice.releaseSamples(.pad, sampleRate: 48_000))
    }

    @Test func aPadIsDeterministic() {
        let c = SynthCoefficients(sampleRate: Self.sampleRate)
        func run() -> [Float] {
            var pad = PadVoice()
            pad.noteOn(.pad, pitch: 60, gateSamples: 48_000, velocity: 0.7, c)
            return (0..<96_000).map { _ in pad.next(c).0 }
        }
        #expect(run() == run())
    }

    // MARK: Through the synth

    @Test func ambientKeysVoicesSoundAndRingOutLong() {
        let scene = Self.renderScene()
        let rate = Int(Self.sampleRate)
        #expect(scene.0.allSatisfy { $0.isFinite } && scene.1.allSatisfy { $0.isFinite })
        #expect(Self.rms(scene.0, 6 * rate..<8 * rate) > 0.005, "the scene is silent")
        // The first chord's gate ends at 7 s; the hall keeps ringing well after.
        #expect(Self.rms(scene.0, 16 * rate..<18 * rate) > 1e-4)
        #expect(scene.0 != scene.1)
    }

    @Test func aSongWithoutPadVoicesIsUntouchedByTheAmbientChain() {
        func render(withAmbientSettings: Bool) -> ([Float], [Float]) {
            let core = DropSynthCore(sampleRate: Self.sampleRate, bpm: 128)
            if withAmbientSettings {
                var space = AmbientSpace()
                space.reverbSeconds = 20
                space.delayMix = 1
                core.setAmbientSpace(space)
            }
            let frames = 512
            let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            defer {
                left.deallocate()
                right.deallocate()
            }
            for note in DemoPattern.notes(in: 0...63) { core.schedule(note) }
            var outLeft: [Float] = []
            var outRight: [Float] = []
            for _ in 0..<200 {
                core.render(frames: frames, left: left, right: right)
                outLeft.append(contentsOf: UnsafeBufferPointer(start: left, count: frames))
                outRight.append(contentsOf: UnsafeBufferPointer(start: right, count: frames))
            }
            return (outLeft, outRight)
        }
        let plain = render(withAmbientSettings: false)
        let configured = render(withAmbientSettings: true)
        #expect(plain.0 == configured.0 && plain.1 == configured.1)
    }

    @Test func ambientSettingsAreClamped() {
        let core = DropSynthCore(sampleRate: Self.sampleRate, bpm: 60)
        var space = AmbientSpace()
        space.reverbSeconds = .infinity
        space.delayFeedback = 9
        space.reverbMix = -3
        core.setAmbientSpace(space)
        let scene = Self.renderScene(seconds: 4)
        #expect(scene.0.allSatisfy { $0.isFinite })
    }

    // MARK: Goldens

    @Test func hallGolden() {
        let response = Self.hallResponse(decay: 8, seconds: 6)
        expectGolden(response.0, response.1, darwin: 0x167e_570f_3e71_ba66, linux: 0x167e_570f_3e71_ba66)
    }

    @Test func delayGolden() {
        let response = Self.echoes(pingPong: true, feedback: 0.6)
        expectGolden(response.0, response.1, darwin: 0x9b87_5220_23eb_1465, linux: 0x9b87_5220_23eb_1465)
    }

    @Test func padGolden() {
        let c = SynthCoefficients(sampleRate: Self.sampleRate)
        var pad = PadVoice()
        var drone = PadVoice()
        pad.noteOn(.pad, pitch: 57, gateSamples: 4 * 48_000, velocity: 0.8, c)
        drone.noteOn(.drone, pitch: 33, gateSamples: 4 * 48_000, velocity: 0.8, c)
        var left: [Float] = []
        var right: [Float] = []
        for _ in 0..<8 * 48_000 {
            let a = pad.next(c)
            let b = drone.next(c)
            left.append(a.0 + b.0)
            right.append(a.1 + b.1)
        }
        expectGolden(left, right, darwin: 0x3b49_2913_50c0_6d78, linux: 0xa642_f773_ad3c_34e3)
    }

    @Test func ambientSceneGolden() throws {
        let scene = Self.renderScene()
        expectGolden(scene.0, scene.1, darwin: 0xc2de_6ee9_6520_e255, linux: 0x9b45_0980_5f0f_0dd8)
        if let directory = ProcessInfo.processInfo.environment["NARDUK_AMBIENT_DEMO_DIR"] {
            try Self.writeWAV(
                scene.0, scene.1, to: URL(fileURLWithPath: directory).appendingPathComponent("ambient-demo.wav"))
        }
    }
}
