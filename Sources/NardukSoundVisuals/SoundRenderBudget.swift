import Foundation

/// How fast the visuals may animate right now (docs/sound-contract.md section 5). One place decides when a stage
/// runs, slows or holds still, so no view takes its rate from the display. Taken from Wirewatcher's `DropFrameRate`,
/// written after a 2026-10-06 WindowServer watchdog panic from rendering every layer at 120 Hz on a hot Mac.
/// The device's thermal pressure, mirroring `ProcessInfo.ThermalState`, which Foundation on Linux does not have.
public enum SoundThermalState: Sendable, Hashable {
    case nominal, fair, serious, critical
}

public enum SoundRenderBudget {
    /// The cap on any display: the visuals are soft glows and beat-locked motion, and 60 fps looks the same as 120.
    public static let normal = 60
    /// `ProcessInfo.ThermalState.serious`, or iOS Low Power Mode: half rate.
    public static let reduced = 30

    /// Frames per second for the stage; 0 means paused, holding the last frame and scheduling nothing.
    /// - Parameters:
    ///   - isVisible: false when the window is minimized, fully occluded or on another Space (macOS), or the scene is
    ///     not active (iOS).
    ///   - thermal: `.critical` holds the stage still; `.serious` drops to `reduced`.
    ///   - lowPowerMode: `ProcessInfo.isLowPowerModeEnabled`; drops to `reduced`.
    public static func framesPerSecond(
        isVisible: Bool, thermal: SoundThermalState, lowPowerMode: Bool = false
    ) -> Int {
        guard isVisible else { return 0 }
        switch thermal {
        case .critical: return 0
        case .serious: return reduced
        default: return lowPowerMode ? reduced : normal
        }
    }

    /// The budget from the process's own thermal and power state.
    public static func current(isVisible: Bool) -> Int {
        #if canImport(Darwin)
            let info = ProcessInfo.processInfo
            let thermal: SoundThermalState
            switch info.thermalState {
            case .nominal: thermal = .nominal
            case .fair: thermal = .fair
            case .serious: thermal = .serious
            case .critical: thermal = .critical
            @unknown default: thermal = .serious
            }
            return framesPerSecond(isVisible: isVisible, thermal: thermal, lowPowerMode: info.isLowPowerModeEnabled)
        #else
            return framesPerSecond(isVisible: isVisible, thermal: .nominal)
        #endif
    }

    /// The effective rate for a view that wants at most `cap` fps under the budget `fps`. At least 1 unless paused.
    public static func rate(_ fps: Int, cap: Int = normal) -> Int {
        fps <= 0 ? 0 : max(1, min(fps, cap))
    }
}

#if canImport(SwiftUI)
    import SwiftUI

    extension SoundRenderBudget {
        /// The `TimelineView` schedule for a view that wants at most `cap` fps under the budget `fps`.
        public static func schedule(_ fps: Int, cap: Int = normal) -> AnimationTimelineSchedule {
            .animation(minimumInterval: 1.0 / Double(max(1, rate(fps, cap: cap))), paused: fps <= 0)
        }
    }

    extension EnvironmentValues {
        /// The stage's frame budget from `SoundRenderBudget`; 0 means paused. Set by the host view; views take their
        /// rate from here and never from the display.
        @Entry public var soundFramesPerSecond: Int = SoundRenderBudget.normal
    }
#endif
