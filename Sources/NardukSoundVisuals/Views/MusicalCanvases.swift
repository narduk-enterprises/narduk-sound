#if canImport(SwiftUI)
    import SwiftUI

    // The two musical Canvas visualizers (narduk-libs#1573): a piano roll and a pitch-class wheel. Both draw from
    // `SoundVisualState.musical`, which reads the music's own notes when the source gives them and the analysis chroma
    // when it does not, so they work on a song, a file and a microphone alike.

    @MainActor extension SoundVisualizers {
        /// The backdrop both musical visualizers paint: the stage color with a faint glow from the palette.
        private static func musicalBackground(
            _ ctx: inout GraphicsContext, _ size: CGSize, _ s: SoundVisualState, _ style: SoundVisualizerStyle,
            center: CGPoint
        ) {
            let rect = CGRect(origin: .zero, size: size)
            ctx.fill(Path(rect), with: .color(style.stage))
            ctx.fill(
                Path(rect),
                with: .radialGradient(
                    Gradient(colors: [SoundCanvas.color(s.palette.c1, 0.07 + 0.10 * Double(s.energy)), .clear]),
                    center: center, startRadius: 0, endRadius: max(size.width, size.height) * 0.7))
        }

        // MARK: Piano roll: a note waterfall

        /// Black keys of an octave, by pitch class: their rows get a darker stripe, as on a piano.
        static func isBlackKey(_ note: Int) -> Bool {
            switch ((note % 12) + 12) % 12 {
            case 1, 3, 6, 8, 10: true
            default: false
            }
        }

        /// The rows the roll shows: the played range padded by a few semitones and at least two octaves, so a single
        /// note does not fill the stage. Nil when nothing has been played in the window.
        static func rollRows(_ range: ClosedRange<Int>?) -> ClosedRange<Int>? {
            guard let range else { return nil }
            let minimum = 24
            var low = range.lowerBound - 2
            var high = range.upperBound + 2
            if high - low + 1 < minimum {
                let extra = minimum - (high - low + 1)
                low -= extra / 2
                high += extra - extra / 2
            }
            if low < 0 {
                high -= low
                low = 0
            }
            if high > SoundMusicalState.noteCount - 1 {
                low -= high - (SoundMusicalState.noteCount - 1)
                high = SoundMusicalState.noteCount - 1
            }
            return max(low, 0)...high
        }

        static func pianoRoll(
            _ ctx: inout GraphicsContext, _ size: CGSize, _ s: SoundVisualState, _ style: SoundVisualizerStyle
        ) {
            musicalBackground(&ctx, size, s, style, center: CGPoint(x: size.width * 0.85, y: size.height / 2))
            let musical = s.musical
            let palette = s.palette
            let columns = SoundMusicalState.rollColumns
            let left: CGFloat = 6
            let area = CGRect(x: left, y: 6, width: max(size.width - left - 6, 1), height: max(size.height - 12, 1))
            let columnWidth = area.width / CGFloat(columns)

            if let rows = rollRows(musical.noteRange) {
                let span = rows.count
                let rowHeight = area.height / CGFloat(span)
                // Piano-key stripes.
                var stripes = Path()
                for note in rows where isBlackKey(note) {
                    let y = area.maxY - CGFloat(note - rows.lowerBound + 1) * rowHeight
                    stripes.addRect(CGRect(x: area.minX, y: y, width: area.width, height: rowHeight))
                }
                ctx.fill(stripes, with: .color(.white.opacity(0.04)))
                // Octave lines at every C.
                var octaves = Path()
                for note in rows where note % 12 == 0 {
                    let y = area.maxY - CGFloat(note - rows.lowerBound) * rowHeight
                    octaves.move(to: CGPoint(x: area.minX, y: y))
                    octaves.addLine(to: CGPoint(x: area.maxX, y: y))
                }
                ctx.stroke(octaves, with: .color(style.label.opacity(0.35)), lineWidth: 0.5)

                // Notes: a held note is one bar across the columns it spans; the first column of a strike is brighter.
                let cells = musical.roll
                let notes = SoundMusicalState.noteCount
                var bright = [Int: Path]()
                var dim = [Int: Path]()
                for note in rows {
                    var runStart: CGFloat?
                    var runEnd: CGFloat = 0
                    var runBright = false
                    func flush() {
                        guard let start = runStart else { return }
                        let y = area.maxY - CGFloat(note - rows.lowerBound + 1) * rowHeight
                        let rect = CGRect(
                            x: start, y: y + rowHeight * 0.1, width: max(runEnd - start, 1), height: rowHeight * 0.8)
                        let path = Path(roundedRect: rect, cornerRadius: min(rowHeight * 0.3, 3))
                        let key = note % 12
                        if runBright {
                            bright[key, default: Path()].addPath(path)
                        } else {
                            dim[key, default: Path()].addPath(path)
                        }
                        runStart = nil
                    }
                    // Oldest on the left: age counts back from the newest column.
                    for age in stride(from: musical.rollCount - 1, through: 0, by: -1) {
                        guard let column = musical.column(age: age) else { continue }
                        let level = cells[column * notes + note]
                        let x = area.maxX - CGFloat(age + 1) * columnWidth
                        if level > 0 {
                            if level >= SoundMusicalState.onsetLevel { flush() }
                            if runStart == nil {
                                runStart = x
                                runBright = level >= SoundMusicalState.onsetLevel
                            }
                            runEnd = x + columnWidth
                        } else {
                            flush()
                        }
                    }
                    flush()
                }
                for (pitchClass, path) in dim {
                    ctx.fill(path, with: .color(SoundCanvas.color(palette.sample(Float(pitchClass) / 12), 0.55)))
                }
                for (pitchClass, path) in bright {
                    let color = SoundCanvas.color(palette.sample(Float(pitchClass) / 12))
                    ctx.drawLayer { layer in
                        layer.addFilter(.blur(radius: 6))
                        layer.fill(path, with: .color(color.opacity(0.6)))
                    }
                    ctx.fill(path, with: .color(color))
                }
            } else {
                // No notes from the source: the analysis chroma over time, 12 rows from B at the top to C at the bottom.
                let rows = SoundMusicalState.pitchClassCount
                let rowHeight = area.height / CGFloat(rows)
                let chroma = musical.chromaRoll
                for pitchClass in 0..<rows {
                    let y = area.maxY - CGFloat(pitchClass + 1) * rowHeight
                    let color = palette.sample(Float(pitchClass) / 12)
                    var lit = Path()
                    for age in 0..<musical.rollCount {
                        guard let column = musical.column(age: age) else { continue }
                        let level = chroma[column * rows + pitchClass]
                        guard level > 0.12 else { continue }
                        let x = area.maxX - CGFloat(age + 1) * columnWidth
                        lit.addRect(
                            CGRect(x: x, y: y + rowHeight * 0.1, width: columnWidth + 0.5, height: rowHeight * 0.8))
                    }
                    ctx.fill(lit, with: .color(SoundCanvas.color(color, 0.78)))
                }
            }

            // The playhead: where "now" lands.
            var now = Path()
            now.move(to: CGPoint(x: area.maxX, y: area.minY))
            now.addLine(to: CGPoint(x: area.maxX, y: area.maxY))
            ctx.soundGlowStroke(now, color: SoundCanvas.color(palette.c2), width: 1.2, glow: 0.6, opacity: 0.8)
        }

        // MARK: Pitch-class wheel

        /// A ring segment as a polygon, angles in radians (0 = 3 o'clock, clockwise on screen).
        private static func wedge(
            center: CGPoint, inner: CGFloat, outer: CGFloat, from start: Double, to end: Double
        ) -> Path {
            var path = Path()
            let steps = max(2, Int(abs(end - start) / 0.05))
            for k in 0...steps {
                let a = start + (end - start) * Double(k) / Double(steps)
                let point = CGPoint(x: center.x + outer * CGFloat(cos(a)), y: center.y + outer * CGFloat(sin(a)))
                if k == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            for k in stride(from: steps, through: 0, by: -1) {
                let a = start + (end - start) * Double(k) / Double(steps)
                path.addLine(to: CGPoint(x: center.x + inner * CGFloat(cos(a)), y: center.y + inner * CGFloat(sin(a))))
            }
            path.closeSubpath()
            return path
        }

        /// The wheel's angle for a pitch class: C at the top, clockwise in semitones.
        static func wheelAngle(_ pitchClass: Int) -> Double {
            (Double(pitchClass) / 12 - 0.25) * 2 * .pi
        }

        static func pitchWheel(
            _ ctx: inout GraphicsContext, _ size: CGSize, _ s: SoundVisualState, _ style: SoundVisualizerStyle
        ) {
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            musicalBackground(&ctx, size, s, style, center: center)
            let musical = s.musical
            let palette = s.palette
            let m = min(size.width, size.height)
            let inner = m * 0.15
            let reach = m * 0.15  // how far a full class grows beyond the base ring
            let base = inner + m * 0.04
            let gap = 0.035
            let slice = 2 * Double.pi / 12
            let values = musical.pitchClasses
            let tonic = musical.keyPitchClass
            let keyed = musical.keyConfidence > 0.2

            // The track: the resting ring.
            for pitchClass in 0..<12 {
                let a0 = wheelAngle(pitchClass) - slice / 2 + gap
                let a1 = wheelAngle(pitchClass) + slice / 2 - gap
                let isTonic = keyed && tonic == pitchClass
                ctx.fill(
                    wedge(center: center, inner: inner, outer: base, from: a0, to: a1),
                    with: .color(isTonic ? SoundCanvas.color(palette.c2, 0.28) : Color.white.opacity(0.06)))
            }
            // The sounding classes: each grows outward with its strength, in its own hue.
            for pitchClass in 0..<12 {
                let value = CGFloat(values[pitchClass])
                guard value > 0.02 else { continue }
                let a0 = wheelAngle(pitchClass) - slice / 2 + gap
                let a1 = wheelAngle(pitchClass) + slice / 2 - gap
                let color = SoundCanvas.color(palette.sample(Float(pitchClass) / 12))
                let path = wedge(center: center, inner: inner, outer: base + reach * value, from: a0, to: a1)
                if value > 0.5 {
                    ctx.drawLayer { layer in
                        layer.addFilter(.blur(radius: 8))
                        layer.fill(path, with: .color(color.opacity(Double(value) * 0.6)))
                    }
                }
                ctx.fill(path, with: .color(color.opacity(0.35 + 0.65 * Double(value))))
            }
            // The key: a bright ring around the tonic's wedge, scaled by how sure the estimate is.
            if keyed, let tonic {
                let a0 = wheelAngle(tonic) - slice / 2 + gap
                let a1 = wheelAngle(tonic) + slice / 2 - gap
                ctx.soundGlowStroke(
                    wedge(center: center, inner: inner, outer: base + reach, from: a0, to: a1),
                    color: SoundCanvas.color(palette.c2), width: 1.4, glow: 0.8,
                    opacity: Double(musical.keyConfidence))
            }
            // Note names around the outside.
            let labelRadius = base + reach + m * 0.045
            let labelSize = max(8, m * 0.04)
            for pitchClass in 0..<12 {
                let angle = wheelAngle(pitchClass)
                let point = CGPoint(
                    x: center.x + labelRadius * CGFloat(cos(angle)), y: center.y + labelRadius * CGFloat(sin(angle)))
                let lit = Double(values[pitchClass])
                ctx.draw(
                    Text(SoundMusicalState.name(ofPitchClass: pitchClass))
                        .font(.system(size: labelSize, weight: lit > 0.5 ? .bold : .regular, design: .monospaced))
                        .foregroundStyle(lit > 0.5 ? Color.white : style.label),
                    at: point)
            }
            // The center: the key's name once there is one.
            if keyed, let tonic {
                ctx.draw(
                    Text(SoundMusicalState.name(ofPitchClass: tonic))
                        .font(.system(size: m * 0.11, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.4 + 0.6 * Double(musical.keyConfidence))),
                    at: CGPoint(x: center.x, y: center.y - m * 0.02))
                ctx.draw(
                    Text(musical.keyIsMinor ? "minor" : "major")
                        .font(.system(size: max(8, m * 0.04), design: .monospaced)).foregroundStyle(style.label),
                    at: CGPoint(x: center.x, y: center.y + m * 0.065))
            }
        }
    }
#endif
