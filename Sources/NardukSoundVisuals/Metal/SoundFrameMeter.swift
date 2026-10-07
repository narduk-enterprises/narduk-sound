#if canImport(Metal)
    import Foundation
    import Metal
    import os

    /// Frame timing for the stage, printed only when the `perfLog` default is on (`-perfLog YES`): GPU time per frame
    /// and the spacing between finished frames, every 3 seconds per visual, so a slow device shows which visual misses
    /// its 16.7ms budget. Off, it costs one Bool read per frame.
    public final class SoundFrameMeter: Sendable {
        public static let shared = SoundFrameMeter()
        public static let isEnabled = UserDefaults.standard.bool(forKey: "perfLog")
        static let windowSeconds = 3.0

        struct Window {
            var label = ""
            var gpu: [Double] = []
            var spacing: [Double] = []
            var lastEnd = 0.0
            var started = 0.0
        }

        private let windows = OSAllocatedUnfairLock(initialState: [String: Window]())

        /// Times `buffer` once the GPU finishes it, under `label` (the visual's name).
        public func track(_ buffer: MTLCommandBuffer, label: String) {
            guard Self.isEnabled else { return }
            buffer.addCompletedHandler { [self] done in
                record(gpuMs: (done.gpuEndTime - done.gpuStartTime) * 1000, end: done.gpuEndTime, label: label)
            }
        }

        private func record(gpuMs: Double, end: Double, label: String) {
            let line: String? = windows.withLock { all in
                var w = all[label] ?? Window(label: label, lastEnd: end, started: end)
                w.gpu.append(gpuMs)
                if end > w.lastEnd { w.spacing.append((end - w.lastEnd) * 1000) }
                w.lastEnd = end
                // A visual that stopped drawing a while ago starts a fresh window rather than reporting the gap.
                if end - w.started > Self.windowSeconds * 2 { w = Window(label: label, lastEnd: end, started: end) }
                defer { all[label] = w }
                guard end - w.started >= Self.windowSeconds, !w.spacing.isEmpty else { return nil }
                let summary = Self.summary(w)
                w = Window(label: label, lastEnd: end, started: end)
                return summary
            }
            if let line { print(line) }
        }

        static func summary(_ w: Window) -> String {
            func pct(_ values: [Double], _ p: Double) -> Double {
                let sorted = values.sorted()
                return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
            }
            let fps = Double(w.spacing.count) / (w.spacing.reduce(0, +) / 1000)
            let late = w.spacing.filter { $0 > 20 }.count
            return String(
                format: "PERF %@ fps=%.1f gpu_p50=%.1fms gpu_p95=%.1fms late=%d/%d", w.label, fps, pct(w.gpu, 0.5),
                pct(w.gpu, 0.95), late, w.spacing.count)
        }
    }
#endif
