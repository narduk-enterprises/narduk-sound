import Testing

/// `-audiodevice <name>` and the device picker resolve a name the way `-autoplay` resolves a source. Headless: no
/// Core Audio device is listed or selected.
@Suite struct InputDeviceTests {
    static let devices = [
        AudioInputDevice(id: 41, name: "BlackHole 2ch"),
        AudioInputDevice(id: 42, name: "BlackHole 16ch"),
        AudioInputDevice(id: 43, name: "MacBook Pro Microphone"),
    ]

    @Test func anExactNameWinsOverAPrefix() {
        #expect(AudioInputDevices.match("BlackHole 2ch", in: Self.devices)?.id == 41)
        #expect(AudioInputDevices.match("blackhole 16CH", in: Self.devices)?.id == 42)
    }

    @Test func aPrefixPicksTheFirstDeviceThatStartsWithIt() {
        #expect(AudioInputDevices.match("black", in: Self.devices)?.id == 41)
        #expect(AudioInputDevices.match(" macbook ", in: Self.devices)?.id == 43)
    }

    @Test func noMatchAndNoNameGiveNil() {
        #expect(AudioInputDevices.match("Scarlett", in: Self.devices) == nil)
        #expect(AudioInputDevices.match("", in: Self.devices) == nil)
        #expect(AudioInputDevices.match("BlackHole", in: []) == nil)
    }
}
