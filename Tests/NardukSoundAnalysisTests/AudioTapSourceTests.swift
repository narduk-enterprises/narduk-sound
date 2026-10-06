#if canImport(AVFoundation)
    import AVFoundation
    import Testing

    @testable import NardukSoundAnalysis

    @Suite struct AudioTapSourceTests {
        /// A 1 kHz sine from a source node into the engine's mixer, rendered offline (no audio device), tapped.
        @Test func mixerTapSeesASineAndStopsCleanly() throws {
            let sampleRate = 48_000.0
            let engine = AVAudioEngine()
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
            nonisolated(unsafe) var phase = 0.0
            let node = AVAudioSourceNode(format: format) { _, _, frames, audioBufferList in
                let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
                for frame in 0..<Int(frames) {
                    let sample = Float(0.5 * sin(phase))
                    phase += 2 * Double.pi * 1_000 / sampleRate
                    for buffer in buffers { buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample }
                }
                return noErr
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)

            let tap = try AudioTapSource.mixer(of: engine)
            #expect(tap.poll(time: 0).sequence == 0)
            try engine.start()
            try tap.start()
            #expect(tap.sampleRate == sampleRate)
            #expect(tap.isRunning)
            let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
            for _ in 0..<8 { _ = try engine.renderOffline(4_096, to: output) }
            engine.stop()
            tap.stop()
            #expect(!tap.isRunning)

            let frame = tap.poll(time: 1)
            #expect(frame.sequence == 1)
            let loudest = frame.spectrum.indices.max { frame.spectrum[$0] < frame.spectrum[$1] } ?? 0
            let center = SpectrumAnalyzer(sampleRate: sampleRate).centerFrequency(ofBand: loudest)
            #expect(center > 850 && center < 1_180, "loudest band centered at \(center) Hz")
            #expect(abs(frame.peakDB - -6) < 1, "peak \(frame.peakDB)")
        }
    }
#endif
