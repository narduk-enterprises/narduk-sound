#if canImport(AVFoundation)
    import AVFoundation
    import Foundation

    public enum AudioTapError: Error, Equatable {
        /// The node has no usable output format yet (no input device, or the audio session is not configured).
        case noFormat
    }

    /// Analyzes whatever flows through an `AVAudioEngine` node: the microphone (`engine.inputNode`), the main mixer
    /// (a file played through a player node, or the whole app's output) or any other node. The tap callback only
    /// downmixes into a `SampleRing`; analysis happens when the display clock polls.
    ///
    /// Start the tap once the graph is connected and the engine is running (a node's format settles then), and
    /// `stop()` it before tearing the engine down. On iOS the microphone needs
    /// `AudioSessionConfiguration.configureForMicrophone()` first; the host app owns the
    /// `NSMicrophoneUsageDescription` string.
    public final class AudioTapSource: SoundFrameSource {
        /// The tapped node's rate, re-read by every `start()` (a device change can move it).
        public private(set) var sampleRate: Double
        private let node: AVAudioNode
        private let bus: AVAudioNodeBus
        private let bufferSize: AVAudioFrameCount
        private var source: RingSource
        private var isInstalled = false

        public init(node: AVAudioNode, bus: AVAudioNodeBus = 0, bufferSize: AVAudioFrameCount = 1_024) throws {
            let format = node.outputFormat(forBus: bus)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioTapError.noFormat }
            self.node = node
            self.bus = bus
            self.bufferSize = bufferSize
            sampleRate = format.sampleRate
            source = RingSource(sampleRate: format.sampleRate)
        }

        /// A tap on the engine's input node.
        public static func microphone(of engine: AVAudioEngine) throws -> AudioTapSource {
            try AudioTapSource(node: engine.inputNode)
        }

        /// A tap on the engine's main mixer: everything the engine plays, files included.
        public static func mixer(of engine: AVAudioEngine) throws -> AudioTapSource {
            try AudioTapSource(node: engine.mainMixerNode)
        }

        public var isRunning: Bool { isInstalled }

        /// Installs the tap. Throws `noFormat` if the node has no format yet (start the engine's session first).
        public func start() throws {
            guard !isInstalled else { return }
            let format = node.outputFormat(forBus: bus)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioTapError.noFormat }
            if format.sampleRate != sampleRate {
                sampleRate = format.sampleRate
                source = RingSource(sampleRate: format.sampleRate)
            }
            let ring = source.ring
            node.installTap(onBus: bus, bufferSize: bufferSize, format: nil) { buffer, _ in
                guard let channels = buffer.floatChannelData else { return }
                ring.write(
                    downmixing: channels, channelCount: Int(buffer.format.channelCount),
                    frameCount: Int(buffer.frameLength))
            }
            isInstalled = true
        }

        public func stop() {
            guard isInstalled else { return }
            node.removeTap(onBus: bus)
            isInstalled = false
        }

        public func poll(time: Double) -> SoundFrame {
            source.poll(time: time)
        }

        deinit {
            if isInstalled { node.removeTap(onBus: bus) }
        }
    }

    #if os(iOS) || os(visionOS) || os(tvOS)
        /// The `AVAudioSession` setup an iOS app needs before it taps the microphone.
        public enum AudioSessionConfiguration {
            /// Play and record in measurement mode (no input processing), mixing with other audio, then activate.
            public static func configureForMicrophone() throws {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(
                    .playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
                try session.setActive(true)
            }
        }
    #endif
#endif
