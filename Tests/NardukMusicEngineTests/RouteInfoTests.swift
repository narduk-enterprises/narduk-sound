import AVFoundation
import Testing

@testable import NardukMusicEngine

#if os(macOS)
    import CoreAudio
#endif

/// `RouteInfo`'s latency arithmetic and its macOS reading. The iOS session figures (`outputLatency`,
/// `ioBufferDuration`, an `.airPlay` port) can only be read on a device.
@MainActor @Suite struct RouteInfoTests {
    @Test func aNewRouteInfoIsZeroAndNotAirPlay() {
        let info = RouteInfo()
        #expect(info.outputLatency == 0)
        #expect(!info.isAirPlay)
    }

    @Test func iOSLatencyIsTheSessionLatencyPlusOneIOBuffer() {
        #expect(RouteInfo.latency(sessionOutputLatency: 0.012, ioBufferDuration: 0.005) == 0.017)
        // AirPlay: seconds of latency.
        #expect(RouteInfo.latency(sessionOutputLatency: 1.8, ioBufferDuration: 0.023) == 1.823)
    }

    @Test func nonsenseLatencyPartsCountAsZero() {
        #expect(RouteInfo.latency(sessionOutputLatency: -1, ioBufferDuration: 0.005) == 0.005)
        #expect(RouteInfo.latency(sessionOutputLatency: .nan, ioBufferDuration: .infinity) == 0)
    }

    @Test func routeInfoComparesByValue() {
        #expect(RouteInfo(outputLatency: 0.1, isAirPlay: true) == RouteInfo(outputLatency: 0.1, isAirPlay: true))
        #expect(RouteInfo(outputLatency: 0.1, isAirPlay: true) != RouteInfo(outputLatency: 0.1, isAirPlay: false))
    }

    #if os(macOS)
        @Test func onlyTheAirPlayTransportIsAirPlay() {
            #expect(RouteInfo.isAirPlay(transportType: kAudioDeviceTransportTypeAirPlay))
            #expect(!RouteInfo.isAirPlay(transportType: kAudioDeviceTransportTypeBuiltIn))
            #expect(!RouteInfo.isAirPlay(transportType: kAudioDeviceTransportTypeBluetooth))
            #expect(!RouteInfo.isAirPlay(transportType: kAudioDeviceTransportTypeUSB))
        }

        /// Reads the real engine and CoreAudio's default output; no sound is made. A runner with no output device
        /// reports not AirPlay and a latency of 0.
        @Test func macOSReadsLatencyFromTheEngineAndTheTransportFromCoreAudio() {
            let info = RouteInfo.current(engine: AVAudioEngine())
            #expect(info.outputLatency.isFinite && info.outputLatency >= 0)
            let transport = RouteInfo.defaultOutputTransportType()
            #expect(info.isAirPlay == (transport.map(RouteInfo.isAirPlay(transportType:)) ?? false))
        }

        @Test func aStartedEnginePublishesItsRouteInfo() throws {
            let engine = DropEngine()
            #expect(engine.routeInfo == RouteInfo())
            engine.offlineFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)
            engine.mutesHardwareOutput = true
            try engine.playDemo()
            defer { engine.stop() }
            #expect(engine.routeInfo.outputLatency.isFinite && engine.routeInfo.outputLatency >= 0)
            // Offline rendering has no output device, so it is never AirPlay.
            #expect(!engine.routeInfo.isAirPlay)
        }
    #endif
}
