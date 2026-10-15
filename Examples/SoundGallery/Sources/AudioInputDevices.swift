import AVFoundation
import Foundation

#if os(macOS)
    import CoreAudio
#endif

/// One audio input the microphone source can tap (narduk-sound: gallery device picker). On macOS that is any Core
/// Audio device with input channels: the built-in microphone, a USB interface, or a loopback driver such as
/// BlackHole, which turns whatever the system plays into an input the visualizers can draw.
struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: UInt32
    let name: String
}

enum AudioInputDevices {
    /// The device whose name matches `name` the way `-autoplay` matches a source: exact first, else the first whose
    /// name starts with it, ignoring case.
    static func match(_ name: String, in devices: [AudioInputDevice]) -> AudioInputDevice? {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return nil }
        return devices.first { $0.name.lowercased() == wanted }
            ?? devices.first { $0.name.lowercased().hasPrefix(wanted) }
    }

    #if os(macOS)
        /// Every device with at least one input channel, in Core Audio's order.
        static func list() -> [AudioInputDevice] {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            let system = AudioObjectID(kAudioObjectSystemObject)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
            var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
            guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
            return ids.compactMap { id in
                guard inputChannels(of: id) > 0, let name = name(of: id) else { return nil }
                return AudioInputDevice(id: id, name: name)
            }
        }

        /// Points the engine's input node at `device`, or back at the system default input for nil. Call it before
        /// the engine starts; the node's format follows the device.
        static func select(_ device: AudioInputDevice?, on node: AVAudioInputNode) throws {
            guard let unit = node.audioUnit else { throw AudioInputDeviceError.noAudioUnit }
            var id: AudioDeviceID
            if let device {
                id = device.id
            } else {
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain)
                var size = UInt32(MemoryLayout<AudioDeviceID>.size)
                id = 0
                let status = AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
                guard status == noErr else { throw AudioInputDeviceError.coreAudio(status) }
            }
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw AudioInputDeviceError.coreAudio(status) }
        }

        private static func inputChannels(of id: AudioDeviceID) -> Int {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
            let raw = UnsafeMutableRawPointer.allocate(
                byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { raw.deallocate() }
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
            let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
            return list.reduce(0) { $0 + Int($1.mNumberChannels) }
        }

        private static func name(of id: AudioDeviceID) -> String? {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr else { return nil }
            return name?.takeRetainedValue() as String?
        }
    #endif
}

enum AudioInputDeviceError: LocalizedError {
    case noAudioUnit
    case coreAudio(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noAudioUnit: "The input node has no audio unit to point at a device."
        case .coreAudio(let status): "Core Audio refused the input device (\(status))."
        }
    }
}
