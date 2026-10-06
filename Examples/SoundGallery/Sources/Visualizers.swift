import NardukSoundAnalysis
import SwiftUI

/// The gallery's palette: a deep background and three accents. Visualizers take colors, never hard-code them.
enum GalleryPalette {
    static let background = Color(red: 0.04, green: 0.05, blue: 0.09)
    static let low = Color(red: 0.98, green: 0.28, blue: 0.45)
    static let mid = Color(red: 0.99, green: 0.76, blue: 0.20)
    static let high = Color(red: 0.25, green: 0.85, blue: 0.95)

    static func color(at position: Double) -> Color {
        position < 0.5 ? blend(low, mid, position * 2) : blend(mid, high, (position - 0.5) * 2)
    }

    private static func blend(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let resolvedA = a.resolve(in: EnvironmentValues())
        let resolvedB = b.resolve(in: EnvironmentValues())
        func mix(_ x: Float, _ y: Float) -> Double { Double(x + (y - x) * Float(t)) }
        return Color(
            red: mix(resolvedA.red, resolvedB.red), green: mix(resolvedA.green, resolvedB.green),
            blue: mix(resolvedA.blue, resolvedB.blue))
    }
}

/// A draw function over one `SoundFrame`: plain Canvas, until NardukSoundVisuals lands.
struct Visualizer: Identifiable {
    let id: String
    let draw: @Sendable (inout GraphicsContext, CGSize, SoundFrame) -> Void

    static let all: [Visualizer] = [
        Visualizer(id: "Spectrum", draw: drawSpectrum),
        Visualizer(id: "Scope", draw: drawScope),
        Visualizer(id: "Levels", draw: drawLevels),
        Visualizer(id: "Radial", draw: drawRadial),
    ]
}

private func drawSpectrum(_ context: inout GraphicsContext, _ size: CGSize, _ frame: SoundFrame) {
    let count = frame.spectrum.count
    let slot = size.width / Double(count)
    for (index, value) in frame.spectrum.enumerated() {
        let height = max(2, size.height * Double(value))
        let rect = CGRect(
            x: Double(index) * slot + slot * 0.12, y: size.height - height, width: slot * 0.76, height: height)
        context.fill(
            Path(roundedRect: rect, cornerRadius: slot * 0.2),
            with: .color(GalleryPalette.color(at: Double(index) / Double(count - 1))))
    }
}

private func drawScope(_ context: inout GraphicsContext, _ size: CGSize, _ frame: SoundFrame) {
    var path = Path()
    let count = frame.waveform.count
    for (index, sample) in frame.waveform.enumerated() {
        let point = CGPoint(
            x: size.width * Double(index) / Double(count - 1),
            y: size.height * (0.5 - 0.45 * Double(max(-1, min(1, sample)))))
        index == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    context.stroke(
        path, with: .color(GalleryPalette.high), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
}

/// dBFS to 0 ... 1 over a -60 ... 0 dB scale.
private func meterFraction(_ decibels: Float) -> Double { Double(max(0, min(1, (decibels + 60) / 60))) }

private func drawLevels(_ context: inout GraphicsContext, _ size: CGSize, _ frame: SoundFrame) {
    for (row, level) in [frame.peakDB, frame.rmsDB].enumerated() {
        let barHeight = size.height * 0.28
        let y = size.height * (0.18 + 0.4 * Double(row))
        let track = CGRect(x: 0, y: y, width: size.width, height: barHeight)
        context.fill(Path(roundedRect: track, cornerRadius: 6), with: .color(.white.opacity(0.08)))
        var fill = track
        fill.size.width = size.width * meterFraction(level)
        context.fill(
            Path(roundedRect: fill, cornerRadius: 6), with: .color(row == 0 ? GalleryPalette.low : GalleryPalette.mid))
    }
}

private func drawRadial(_ context: inout GraphicsContext, _ size: CGSize, _ frame: SoundFrame) {
    let center = CGPoint(x: size.width / 2, y: size.height / 2)
    let inner = min(size.width, size.height) * 0.18
    let outer = min(size.width, size.height) * 0.46
    let count = frame.spectrum.count
    for (index, value) in frame.spectrum.enumerated() {
        let angle = 2 * Double.pi * Double(index) / Double(count) - Double.pi / 2
        let length = inner + (outer - inner) * Double(value)
        var path = Path()
        path.move(to: CGPoint(x: center.x + inner * cos(angle), y: center.y + inner * sin(angle)))
        path.addLine(to: CGPoint(x: center.x + length * cos(angle), y: center.y + length * sin(angle)))
        context.stroke(
            path, with: .color(GalleryPalette.color(at: Double(index) / Double(count))),
            style: StrokeStyle(lineWidth: 3, lineCap: .round))
    }
}
