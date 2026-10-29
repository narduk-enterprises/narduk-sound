import AVFoundation
import Foundation

#if os(macOS)
    import CoreAudio
#endif

/// Where the sound is going right now, published by `DropEngine.routeInfo` and refreshed on every route change.
public struct RouteInfo: Sendable, Equatable {
    /// Seconds from a sample leaving the synth to it reaching the air: on iOS the session's `outputLatency` plus its
    /// `ioBufferDuration`, on macOS the output node's presentation latency. AirPlay routes sit in the seconds, so
    /// a visual that must land on the beat reads this. 0 until the engine has been started.
    public var outputLatency: TimeInterval
    /// True when the output is an AirPlay device (an AirPlay 2 speaker, a HomePod, an Apple TV).
    public var isAirPlay: Bool

    public init(outputLatency: TimeInterval = 0, isAirPlay: Bool = false) {
        self.outputLatency = outputLatency
        self.isAirPlay = isAirPlay
    }

    /// The iOS figure: the session's output latency plus one IO buffer. Non-finite or negative parts count as 0.
    static func latency(sessionOutputLatency: TimeInterval, ioBufferDuration: TimeInterval) -> TimeInterval {
        func clean(_ seconds: TimeInterval) -> TimeInterval { seconds.isFinite ? max(seconds, 0) : 0 }
        return clean(sessionOutputLatency) + clean(ioBufferDuration)
    }

    #if os(macOS)
        /// CoreAudio's `kAudioDeviceTransportTypeAirPlay` ('airp') identifies an AirPlay output device.
        static func isAirPlay(transportType: UInt32) -> Bool {
            transportType == kAudioDeviceTransportTypeAirPlay
        }

        /// The transport type of the system's default output device, nil when there is none.
        static func defaultOutputTransportType() -> UInt32? {
            var device = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            guard
                AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
                    == noErr, device != AudioObjectID(kAudioObjectUnknown)
            else { return nil }
            var transport: UInt32 = 0
            size = UInt32(MemoryLayout<UInt32>.size)
            address.mSelector = kAudioDevicePropertyTransportType
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return nil }
            return transport
        }

        /// Reads the live route: the engine's output latency and the default device's transport.
        static func current(engine: AVAudioEngine) -> RouteInfo {
            let latency = engine.outputNode.presentationLatency
            return RouteInfo(
                outputLatency: latency.isFinite ? max(latency, 0) : 0,
                isAirPlay: defaultOutputTransportType().map(isAirPlay(transportType:)) ?? false)
        }
    #else
        /// Reads the live route from the shared audio session.
        static func current(engine: AVAudioEngine) -> RouteInfo {
            let session = AVAudioSession.sharedInstance()
            return RouteInfo(
                outputLatency: latency(
                    sessionOutputLatency: session.outputLatency, ioBufferDuration: session.ioBufferDuration),
                isAirPlay: session.currentRoute.outputs.contains { $0.portType == .airPlay })
        }
    #endif
}
