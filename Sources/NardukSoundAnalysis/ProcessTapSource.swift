#if os(macOS)
    import CoreAudio
    import Foundation
    import Synchronization

    /// Why a `ProcessTapSource` could not start.
    @available(macOS 14.2, *)
    public enum ProcessTapError: Error, Equatable {
        /// The process has no Core Audio process object: it is not running, or has never touched audio.
        case processNotFound(String)
        case tapCreationFailed(OSStatus)
        case aggregateDeviceFailed(OSStatus)
        /// The tap's stream is not 32-bit float PCM, or its format could not be read.
        case formatUnavailable(OSStatus)
        case ioProcFailed(OSStatus)
        case startFailed(OSStatus)
        /// A muted tap was asked for but Core Audio reports the tap as not muted. The source tears itself down
        /// rather than let the process play aloud.
        case notMuted
    }

    /// One process Core Audio knows about, from `ProcessTapSource.audioProcesses()`.
    @available(macOS 14.2, *)
    public struct AudioProcessInfo: Sendable, Hashable {
        public var objectID: UInt32
        public var pid: Int32
        public var bundleID: String
        /// Whether the process is rendering audio to an output device right now.
        public var isRunningOutput: Bool
    }

    /// Silent, per-process capture of what one Mac app plays, as a `SoundFrameSource`: a Core Audio process tap
    /// (`AudioHardwareCreateProcessTap`, macOS 14.2+) on a single process, muted by default so the process makes no
    /// sound while it is tapped, read through a private aggregate device by an IOProc that downmixes into a
    /// `SampleRing`. Analysis happens when the display clock polls, as for `AudioTapSource`.
    ///
    /// The first start on a Mac asks the person for the one-time "System Audio Recording" permission, attributed to
    /// the app that launched the process; without it the tap delivers silence, not an error.
    ///
    /// Order matters for silence: create the source, `start()` (which refuses to run a muted tap that reads back as
    /// unmuted), and only then let the target process play. `stop()` destroys the IOProc, the aggregate device and
    /// the tap, in that order.
    @available(macOS 14.2, *)
    public final class ProcessTapSource: SoundFrameSource {
        public enum Target: Equatable, Sendable {
            case pid(Int32)
            case bundleID(String)
        }

        /// The tap's rate, re-read by every `start()`.
        public private(set) var sampleRate: Double
        public let target: Target
        /// Whether the tapped process is silenced on the hardware while tapped. Default true.
        public let mute: Bool
        /// Seconds of stereo to keep for `recordedStereo()`; 0 (the default) records nothing.
        public let recordSeconds: Double

        /// Frames between the process producing a sample and the IOProc seeing it: the aggregate device's
        /// `kAudioDevicePropertyLatency` plus `kAudioDevicePropertySafetyOffset` (input scope). 0 until started.
        public private(set) var latencyFrames = 0
        /// The aggregate device's IO buffer size in frames (`kAudioDevicePropertyBufferFrameSize`).
        public private(set) var bufferFrames = 0
        /// `latencyFrames` in seconds: what a sync stage subtracts from a capture time.
        public var latencySeconds: Double { sampleRate > 0 ? Double(latencyFrames) / sampleRate : 0 }
        /// Latency plus one buffer: the time from a process rendering a sample to the analyzer being able to see it.
        public var presentationLatency: Double {
            sampleRate > 0 ? Double(latencyFrames + bufferFrames) / sampleRate : 0
        }

        /// How many times the IOProc has run since `start()`: proof the tap is live before the process plays.
        public var callbackCount: Int { state?.callbackCount ?? 0 }
        /// Core Audio host time (`mach_absolute_time` units) of the first captured frame since `start()`, or 0 before
        /// the first callback. With `recordedStereo()` it dates any captured event on the host clock.
        public var captureStartHostTime: UInt64 { state?.firstHostTime.load(ordering: .acquiring) ?? 0 }

        /// Core Audio's reading of the live tap's mute behavior (nil before `start()`).
        public private(set) var tapReadsMuted: Bool?
        /// The aggregate device's UID while running (so a caller can prove it is gone after `stop()`), else nil.
        public private(set) var aggregateUID: String?
        public private(set) var tapUID: String?

        /// The first non-zero Core Audio status from the last `stop()` (0 when every object was destroyed cleanly).
        public private(set) var teardownStatus: OSStatus = noErr

        private var source: RingSource
        private var state: ProcessTapState?
        private var tapID = AudioObjectID(kAudioObjectUnknown)
        private var aggregateID = AudioObjectID(kAudioObjectUnknown)
        private var ioProcID: AudioDeviceIOProcID?

        public init(target: Target, mute: Bool = true, recordSeconds: Double = 0) {
            self.target = target
            self.mute = mute
            self.recordSeconds = max(recordSeconds, 0)
            sampleRate = 48_000
            source = RingSource(sampleRate: 48_000)
        }

        public convenience init(pid: Int32, mute: Bool = true, recordSeconds: Double = 0) {
            self.init(target: .pid(pid), mute: mute, recordSeconds: recordSeconds)
        }

        public convenience init(bundleID: String, mute: Bool = true, recordSeconds: Double = 0) {
            self.init(target: .bundleID(bundleID), mute: mute, recordSeconds: recordSeconds)
        }

        public var isRunning: Bool { ioProcID != nil }

        // MARK: - Description and process lookup (no tap is created)

        /// The tap description `start()` creates: a stereo mixdown of exactly this one process, private to this
        /// client, muted or not as asked.
        static func makeDescription(processObject: AudioObjectID, mute: Bool, uuid: UUID = UUID()) -> CATapDescription {
            let description = CATapDescription(stereoMixdownOfProcesses: [processObject])
            description.uuid = uuid
            description.name = "NardukSound process tap"
            description.isPrivate = true
            description.muteBehavior = mute ? .muted : .unmuted
            return description
        }

        /// Every process Core Audio currently has an object for.
        public static func audioProcesses() -> [AudioProcessInfo] {
            let system = AudioObjectID(kAudioObjectSystemObject)
            return objectIDs(of: system, selector: kAudioHardwarePropertyProcessObjectList).map { object in
                AudioProcessInfo(
                    objectID: object,
                    pid: scalar(of: object, selector: kAudioProcessPropertyPID, default: Int32(-1)),
                    bundleID: string(of: object, selector: kAudioProcessPropertyBundleID) ?? "",
                    isRunningOutput: scalar(
                        of: object, selector: kAudioProcessPropertyIsRunningOutput, default: UInt32(0))
                        != 0)
            }
        }

        /// The Core Audio process object for a PID, or nil if the process has none.
        public static func processObject(forPID pid: Int32) -> AudioObjectID? {
            var qualifier = pid_t(pid)
            var object = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            var address = propertyAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
            let status = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &qualifier,
                &size, &object)
            guard status == noErr, object != AudioObjectID(kAudioObjectUnknown) else { return nil }
            return object
        }

        /// The Core Audio process object whose bundle identifier matches, or nil. When several processes share the
        /// bundle ID, the one rendering output wins.
        public static func processObject(forBundleID bundleID: String) -> AudioObjectID? {
            let matches = audioProcesses().filter { $0.bundleID == bundleID }
            return (matches.first { $0.isRunningOutput } ?? matches.first)?.objectID
        }

        // MARK: - Lifecycle

        /// Creates the tap, the private aggregate device and the IOProc, and starts it. Throws if the process has
        /// no audio object yet (start playing something first, or retry), and tears down whatever it built.
        public func start() throws {
            guard !isRunning else { return }
            let object: AudioObjectID?
            let label: String
            switch target {
            case .pid(let pid):
                object = Self.processObject(forPID: pid)
                label = "pid \(pid)"
            case .bundleID(let id):
                object = Self.processObject(forBundleID: id)
                label = id
            }
            guard let object else { throw ProcessTapError.processNotFound(label) }
            do {
                try build(processObject: object)
            } catch {
                teardown()
                throw error
            }
        }

        public func stop() {
            teardown()
        }

        public func poll(time: Double) -> SoundFrame {
            source.poll(time: time)
        }

        /// The stereo audio captured since `start()` (interleaved L, R), at most `recordSeconds` of it. Empty when
        /// `recordSeconds` is 0. Call after `stop()` (it is also safe while running).
        public func recordedStereo() -> [Float] {
            state?.recorded() ?? lastRecording
        }
        private var lastRecording: [Float] = []

        deinit { teardown() }

        // MARK: - Build and teardown

        private func build(processObject: AudioObjectID) throws {
            let uuid = UUID()
            let description = Self.makeDescription(processObject: processObject, mute: mute, uuid: uuid)
            var status = AudioHardwareCreateProcessTap(description, &tapID)
            guard status == noErr else {
                tapID = AudioObjectID(kAudioObjectUnknown)
                throw ProcessTapError.tapCreationFailed(status)
            }
            tapUID = uuid.uuidString

            let liveDescription: CATapDescription? = readObject(of: tapID, selector: kAudioTapPropertyDescription)
            tapReadsMuted = liveDescription.map { $0.muteBehavior == .muted }
            if mute, tapReadsMuted != true { throw ProcessTapError.notMuted }

            var format = AudioStreamBasicDescription()
            var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var formatAddress = Self.propertyAddress(kAudioTapPropertyFormat)
            status = AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &formatSize, &format)
            guard status == noErr else { throw ProcessTapError.formatUnavailable(status) }
            guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                format.mBitsPerChannel == 32, format.mSampleRate > 0
            else { throw ProcessTapError.formatUnavailable(kAudio_ParamError) }
            if format.mSampleRate != sampleRate {
                sampleRate = format.mSampleRate
                source = RingSource(sampleRate: format.mSampleRate)
            }

            let aggregateUID = "com.nardukenterprises.process-tap.\(uuid.uuidString)"
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "NardukSound process tap",
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapUIDKey: uuid.uuidString,
                        kAudioSubTapDriftCompensationKey: true,
                    ]
                ],
            ]
            status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
            guard status == noErr else {
                aggregateID = AudioObjectID(kAudioObjectUnknown)
                throw ProcessTapError.aggregateDeviceFailed(status)
            }
            self.aggregateUID = aggregateUID

            let newState = ProcessTapState(
                ring: source.ring, sampleRate: format.mSampleRate,
                recordFrames: Int(recordSeconds * format.mSampleRate))
            state = newState
            var procID: AudioDeviceIOProcID?
            status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, inputTime, _, _ in
                newState.consume(input, hostTime: inputTime.pointee.mHostTime)
            }
            guard status == noErr, let procID else { throw ProcessTapError.ioProcFailed(status) }
            ioProcID = procID

            latencyFrames =
                Int(
                    Self.scalar(
                        of: aggregateID, selector: kAudioDevicePropertyLatency, scope: kAudioObjectPropertyScopeInput,
                        default: UInt32(0)))
                + Int(
                    Self.scalar(
                        of: aggregateID, selector: kAudioDevicePropertySafetyOffset,
                        scope: kAudioObjectPropertyScopeInput, default: UInt32(0)))
            bufferFrames = Int(
                Self.scalar(of: aggregateID, selector: kAudioDevicePropertyBufferFrameSize, default: UInt32(0)))

            status = AudioDeviceStart(aggregateID, procID)
            guard status == noErr else { throw ProcessTapError.startFailed(status) }
        }

        private func teardown() {
            var firstFailure = noErr
            func note(_ status: OSStatus) { if firstFailure == noErr { firstFailure = status } }
            if let procID = ioProcID, aggregateID != AudioObjectID(kAudioObjectUnknown) {
                note(AudioDeviceStop(aggregateID, procID))
                note(AudioDeviceDestroyIOProcID(aggregateID, procID))
            }
            ioProcID = nil
            if aggregateID != AudioObjectID(kAudioObjectUnknown) {
                note(AudioHardwareDestroyAggregateDevice(aggregateID))
                aggregateID = AudioObjectID(kAudioObjectUnknown)
            }
            if tapID != AudioObjectID(kAudioObjectUnknown) {
                note(AudioHardwareDestroyProcessTap(tapID))
                tapID = AudioObjectID(kAudioObjectUnknown)
            }
            if let state { lastRecording = state.recorded() }
            state = nil
            aggregateUID = nil
            tapUID = nil
            tapReadsMuted = nil
            teardownStatus = firstFailure
        }

        // MARK: - Core Audio property helpers

        private static func propertyAddress(
            _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
        ) -> AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        }

        private static func scalar<T: BitwiseCopyable>(
            of object: AudioObjectID, selector: AudioObjectPropertySelector,
            scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default value: T
        ) -> T {
            var result = value
            var size = UInt32(MemoryLayout<T>.size)
            var address = propertyAddress(selector, scope: scope)
            guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr else { return value }
            return result
        }

        private static func objectIDs(of object: AudioObjectID, selector: AudioObjectPropertySelector)
            -> [AudioObjectID]
        {
            var address = propertyAddress(selector)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
            var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
            guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
            return ids
        }

        private static func string(of object: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
            var value: Unmanaged<CFString>?
            var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var address = propertyAddress(selector)
            guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
            return value?.takeRetainedValue() as String?
        }

        private func readObject<T: AnyObject>(of object: AudioObjectID, selector: AudioObjectPropertySelector) -> T? {
            var value: Unmanaged<T>?
            var size = UInt32(MemoryLayout<Unmanaged<T>?>.size)
            var address = Self.propertyAddress(selector)
            guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
            return value?.takeRetainedValue()
        }
    }

    /// What the IOProc touches on the audio thread: a mono ring, a scratch buffer and an optional stereo recorder,
    /// all allocated before the device starts. The IOProc never allocates, locks or retains.
    @available(macOS 14.2, *)
    private final class ProcessTapState: @unchecked Sendable {
        private let ring: SampleRing
        private let scratch: UnsafeMutablePointer<Float>
        private let scratchCount = 8_192
        private let recording: UnsafeMutablePointer<Float>
        private let recordCapacity: Int
        private let recordedFrames = Atomic<Int>(0)
        private let callbacks = Atomic<Int>(0)
        let firstHostTime = Atomic<UInt64>(0)

        var callbackCount: Int { callbacks.load(ordering: .acquiring) }

        init(ring: SampleRing, sampleRate: Double, recordFrames: Int) {
            self.ring = ring
            scratch = .allocate(capacity: scratchCount)
            scratch.initialize(repeating: 0, count: scratchCount)
            recordCapacity = max(recordFrames, 0)
            recording = .allocate(capacity: max(recordCapacity * 2, 1))
            recording.initialize(repeating: 0, count: max(recordCapacity * 2, 1))
        }

        deinit {
            scratch.deallocate()
            recording.deallocate()
        }

        /// Interleaved L, R for the first `recordSeconds` of audio.
        func recorded() -> [Float] {
            let frames = min(recordedFrames.load(ordering: .acquiring), recordCapacity)
            return Array(UnsafeBufferPointer(start: recording, count: frames * 2))
        }

        /// Downmixes every channel of every buffer to mono into the ring, and the first two channels to the recorder.
        func consume(_ input: UnsafePointer<AudioBufferList>, hostTime: UInt64) {
            if callbacks.load(ordering: .relaxed) == 0 { firstHostTime.store(hostTime, ordering: .releasing) }
            defer { callbacks.add(1, ordering: .releasing) }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            var frames = Int.max
            var channelCount = 0
            for buffer in buffers where buffer.mData != nil && buffer.mNumberChannels > 0 {
                frames = min(
                    frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * Int(buffer.mNumberChannels)))
                channelCount += Int(buffer.mNumberChannels)
            }
            guard channelCount > 0, frames > 0, frames != Int.max else { return }
            let gain = 1 / Float(channelCount)
            var done = 0
            while done < frames {
                let chunk = min(scratchCount, frames - done)
                for i in 0..<chunk { scratch[i] = 0 }
                for buffer in buffers where buffer.mData != nil && buffer.mNumberChannels > 0 {
                    let data = buffer.mData!.assumingMemoryBound(to: Float.self)
                    let stride = Int(buffer.mNumberChannels)
                    for i in 0..<chunk {
                        var sum: Float = 0
                        for c in 0..<stride { sum += data[(done + i) * stride + c] }
                        scratch[i] += sum * gain
                    }
                }
                ring.write(scratch, count: chunk)
                done += chunk
            }
            record(buffers, frames: frames)
        }

        private func record(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
            let written = recordedFrames.load(ordering: .relaxed)
            guard recordCapacity > written else { return }
            var left: (UnsafeMutablePointer<Float>, Int)?
            var right: (UnsafeMutablePointer<Float>, Int)?
            for buffer in buffers where buffer.mData != nil && buffer.mNumberChannels > 0 {
                let data = buffer.mData!.assumingMemoryBound(to: Float.self)
                let stride = Int(buffer.mNumberChannels)
                for c in 0..<stride {
                    if left == nil {
                        left = (data + c, stride)
                    } else if right == nil {
                        right = (data + c, stride)
                    }
                }
            }
            guard let left else { return }
            let right2 = right ?? left
            let count = min(frames, recordCapacity - written)
            for i in 0..<count {
                recording[(written + i) * 2] = left.0[i * left.1]
                recording[(written + i) * 2 + 1] = right2.0[i * right2.1]
            }
            recordedFrames.store(written + count, ordering: .releasing)
        }
    }
#endif
