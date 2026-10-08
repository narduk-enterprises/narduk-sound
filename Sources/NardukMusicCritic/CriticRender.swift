import Foundation
import NardukMusicCore
import NardukMusicDSP
import NardukMusicRender

/// An offline render that also records what the critic needs: the conductor's notes and its section and energy at
/// every bar line, the time each synth block took, and where each kick and snare was due.
///
/// It is `OfflineRenderer`'s tick loop, step for step (60 ticks a second, notes 100 ms ahead of the render position,
/// tempo changes followed once audible), driving `DropSynthCore` directly so the synth's own render call can be timed
/// apart from the conductor. `CriticRenderTests` holds it to the same samples as `OfflineRenderer`, bit for bit.
final class CriticRender {
    struct DueHit {
        /// The sample the synth fires the note on (its step on the synth's clock, plus its swing).
        var sample: Int
        /// The swing part of `sample`, in samples.
        var swing: Int
        var instrument: Instrument
    }

    let settings: SongSettings
    let sampleRate: Double
    let framesPerTick: Int
    /// Which conductor notes reach the synth (all of them when nil); every note is still recorded.
    let filter: ((ScheduledNote) -> Bool)?
    /// The instruments whose due samples are recorded.
    let tracked: Set<Instrument>

    private(set) var notes: [ScheduledNote] = []
    private(set) var sections: [SongSection] = []
    private(set) var energy: [Double] = []
    private(set) var due: [DueHit] = []
    /// Nanoseconds of each `DropSynthCore.render` call and of each tick's note pump.
    private(set) var renderNanos: [UInt64] = []
    private(set) var pumpNanos: [UInt64] = []

    private let core: DropSynthCore
    private var conductor: DropConductor
    private var bpm: Double
    private var clock: StepClock
    private var requestedMilli: Int
    private var pending: [ScheduledNote] = []
    private var scheduledThrough = -1
    private var appliedSwitchStep: Int?
    private var left: [Float]
    private var right: [Float]

    init(
        settings: SongSettings, sampleRate: Double = 48_000, filter: ((ScheduledNote) -> Bool)? = nil,
        tracked: Set<Instrument> = []
    ) {
        self.settings = settings
        self.sampleRate = sampleRate
        self.filter = filter
        self.tracked = tracked
        framesPerTick = Int(sampleRate / OfflineRenderer.tickRate)
        core = DropSynthCore(sampleRate: sampleRate, bpm: settings.bpm, stepsPerBar: settings.stepsPerBar)
        core.setMasterVolume(0.8)
        conductor = DropConductor(settings: settings)
        bpm = settings.bpm
        clock = StepClock(sampleRate: Int(sampleRate), bpm: settings.bpm)
        requestedMilli = StepClock.milliBPM(settings.bpm)
        left = [Float](repeating: 0, count: framesPerTick)
        right = [Float](repeating: 0, count: framesPerTick)
        pumpNotes()
    }

    /// The synth's step position at the end of what has been rendered.
    var renderedStepPosition: Double { core.renderedStepPosition }

    /// Samples of delay the synth's master limiter adds.
    var limiterLatency: Int { core.limiterLatency }

    /// Renders `ticks` ticks, delivering each signal in the tick its time falls in (as `OfflineRenderer.render` does
    /// for a scenario), and returns the audio.
    func render(ticks: Int, signals: [MusicSignal]) -> RenderedAudio {
        var signals = signals[...]
        var outLeft: [Float] = []
        var outRight: [Float] = []
        outLeft.reserveCapacity(ticks * framesPerTick)
        outRight.reserveCapacity(ticks * framesPerTick)
        renderNanos.reserveCapacity(ticks)
        pumpNanos.reserveCapacity(ticks)
        for tick in 0..<ticks {
            let end = Double(tick + 1) / OfflineRenderer.tickRate
            let pumpStart = DispatchTime.now().uptimeNanoseconds
            while let signal = signals.first, signal.time < end {
                conductor.ingest(signal)
                signals = signals.dropFirst()
            }
            let latency = Double(core.lastBufferFrames) / core.sampleRate
            let currentStep = Int(max(core.renderedStepPosition - latency / (60 / bpm / 4), 0))
            pumpNotes()
            followTempo(currentStep: currentStep)
            pumpNanos.append(DispatchTime.now().uptimeNanoseconds - pumpStart)

            // The synth's clock, mirrored: it takes a tempo request at the start of the buffer.
            let start = core.renderedSampleCount
            clock.advance(to: start)
            if requestedMilli != clock.targetBpmMilli {
                clock.requestTempo(milli: requestedMilli, currentSample: start, stepsPerBar: settings.stepsPerBar)
            }
            let count = framesPerTick
            let renderStart = DispatchTime.now().uptimeNanoseconds
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    core.render(frames: count, left: l.baseAddress!, right: r.baseAddress!)
                }
            }
            renderNanos.append(DispatchTime.now().uptimeNanoseconds - renderStart)
            recordDue(before: start + count)
            outLeft += left
            outRight += right
        }
        return RenderedAudio(sampleRate: sampleRate, left: outLeft, right: outRight)
    }

    private func pumpNotes() {
        let through = Int(core.renderedStepPosition + OfflineRenderer.lookaheadSeconds / (60 / bpm / 4))
        guard through > scheduledThrough else { return }
        for step in (scheduledThrough + 1)...through {
            let written = conductor.advance(throughStep: step)
            if step % settings.stepsPerBar == 0 {
                sections.append(conductor.snapshot.section)
                energy.append(conductor.snapshot.energy)
            }
            notes += written
            for note in written where filter?(note) ?? true {
                core.schedule(note)
                if tracked.contains(note.instrument) { pending.append(note) }
            }
        }
        scheduledThrough = through
    }

    private func followTempo(currentStep: Int) {
        guard let change = conductor.lastSwitch, change.step != appliedSwitchStep, currentStep >= change.step else {
            return
        }
        appliedSwitchStep = change.step
        if bpm != change.bpm {
            bpm = change.bpm
            core.setTempo(change.bpm)
            requestedMilli = StepClock.milliBPM(change.bpm)
        }
    }

    /// Moves every tracked note the synth has fired by `end` into `due`, using the clock as it stood for this buffer.
    private func recordDue(before end: Int) {
        var index = 0
        while index < pending.count {
            let note = pending[index]
            let grid = clock.sample(forStep: note.step)
            let delay = Float(min(max(note.params.delay ?? 0, 0), 0.5))
            let swing = delay > 0 ? Int(Double(delay) * clock.samplesPerStep) : 0
            if grid + swing < end {
                due.append(DueHit(sample: grid + swing, swing: swing, instrument: note.instrument))
                pending.swapAt(index, pending.count - 1)
                pending.removeLast()
            } else {
                index += 1
            }
        }
    }
}
