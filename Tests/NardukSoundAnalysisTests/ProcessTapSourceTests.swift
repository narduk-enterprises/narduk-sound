#if os(macOS)
    import CoreAudio
    import Foundation
    import Testing

    @testable import NardukSoundAnalysis

    @Suite struct ProcessTapSourceTests {
        // MARK: - Runs everywhere: no tap, aggregate device or IOProc is created

        @Test func descriptionTapsExactlyOneProcessAndMutesIt() {
            let uuid = UUID()
            let description = ProcessTapSource.makeDescription(processObject: 4_242, mute: true, uuid: uuid)
            #expect(description.processes == [4_242])
            #expect(description.muteBehavior == .muted)
            #expect(description.uuid == uuid)
            #expect(description.isPrivate)
            #expect(description.isMixdown)
            #expect(!description.isMono)
            // A global tap would name every process but a few; this one must be inclusive.
            #expect(!description.isExclusive)
        }

        @Test func descriptionCanLeaveTheProcessAudible() {
            let description = ProcessTapSource.makeDescription(processObject: 7, mute: false)
            #expect(description.muteBehavior == .unmuted)
        }

        @Test func muteIsOnByDefault() {
            #expect(ProcessTapSource(pid: 1).mute)
            #expect(ProcessTapSource(bundleID: "com.apple.Music").mute)
            #expect(!ProcessTapSource(pid: 1, mute: false).mute)
        }

        @Test func aProcessWithNoAudioObjectIsNotFound() {
            // Far above any PID the kernel hands out.
            #expect(ProcessTapSource.processObject(forPID: 2_000_000_000) == nil)
            #expect(ProcessTapSource.processObject(forBundleID: "invalid.example.no-such-bundle") == nil)
        }

        @Test func startingOnAMissingProcessThrowsAndLeavesNothingRunning() {
            let source = ProcessTapSource(pid: 2_000_000_000)
            #expect(throws: ProcessTapError.processNotFound("pid 2000000000")) { try source.start() }
            #expect(!source.isRunning)
            #expect(source.aggregateUID == nil)
            #expect(source.tapUID == nil)
            #expect(source.callbackCount == 0)
        }

        @Test func stopIsHarmlessBeforeStartAndTwice() {
            let source = ProcessTapSource(bundleID: "invalid.example.no-such-bundle")
            source.stop()
            source.stop()
            #expect(!source.isRunning)
            #expect(source.recordedStereo().isEmpty)
        }

        @Test func pollBeforeStartIsTheEmptyFrameAndLatencyIsZero() {
            let source = ProcessTapSource(pid: 1)
            #expect(source.poll(time: 0).sequence == 0)
            #expect(source.sampleRate == 48_000)
            #expect(source.latencyFrames == 0)
            #expect(source.presentationLatency == 0)
        }

        @Test func theProcessListIsReadableAndSelfConsistent() {
            for process in ProcessTapSource.audioProcesses() where !process.bundleID.isEmpty {
                #expect(process.pid > 0)
                #expect(ProcessTapSource.processObject(forPID: process.pid) == process.objectID)
            }
        }

        // MARK: - Live tap, gated: `PROCESS_TAP_PID=<pid> swift test --filter ProcessTapSourceTests`

        /// A real muted tap on the process named by `PROCESS_TAP_PID`, started and stopped twice. The first start on a
        /// Mac may raise the system-audio permission prompt and run under `xctest`, so it never runs unasked: CI sets
        /// no variable. The probe in Examples/ProcessTapProbe is the better way to run it for a person to approve.
        @Test(.enabled(if: ProcessInfo.processInfo.environment["PROCESS_TAP_PID"] != nil))
        func liveTapStartsStopsTwiceAndLeavesNothingBehind() throws {
            let pid = try #require(Int32(ProcessInfo.processInfo.environment["PROCESS_TAP_PID"] ?? ""))
            let tapsBefore = Self.tapCount()
            let devicesBefore = Self.deviceCount()
            let source = ProcessTapSource(pid: pid, mute: true, recordSeconds: 1)
            for _ in 0..<2 {
                try source.start()
                #expect(source.isRunning)
                #expect(source.tapReadsMuted == true)
                let uid = try #require(source.aggregateUID)
                #expect(Self.deviceExists(uid: uid), "the aggregate device is live while running")
                #expect(Self.tapCount() == tapsBefore + 1)
                #expect(source.sampleRate > 0 && source.bufferFrames > 0)
                Thread.sleep(forTimeInterval: 0.5)
                if source.callbackCount > 0 {
                    #expect(source.poll(time: 1).sequence > 0)
                    #expect(source.captureStartHostTime > 0)
                }
                source.stop()
                #expect(!source.isRunning)
                #expect(source.teardownStatus == noErr, "teardown status \(source.teardownStatus)")
                // The HAL removes destroyed objects asynchronously; allow it a moment before calling it a leak.
                let gone = Self.waitUntil {
                    !Self.deviceExists(uid: uid) && Self.tapCount() == tapsBefore && Self.deviceCount() == devicesBefore
                }
                #expect(gone, "the aggregate device and tap are gone after stop()")
            }
        }

        // MARK: - Core Audio reads for the leak check

        private static func count(of selector: AudioObjectPropertySelector) -> Int {
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            guard
                AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
                    == noErr
            else { return 0 }
            return Int(size) / MemoryLayout<AudioObjectID>.size
        }

        private static func waitUntil(timeout: Double = 3, _ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() {
                if Date() > deadline { return false }
                Thread.sleep(forTimeInterval: 0.05)
            }
            return true
        }

        private static func tapCount() -> Int { count(of: kAudioHardwarePropertyTapList) }
        private static func deviceCount() -> Int { count(of: kAudioHardwarePropertyDevices) }

        private static func deviceExists(uid: String) -> Bool {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var qualifier = uid as CFString
            var device = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            let status = withUnsafeMutablePointer(to: &qualifier) { pointer in
                AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), pointer,
                    &size, &device)
            }
            return status == noErr && device != AudioObjectID(kAudioObjectUnknown)
        }
    }
#endif
