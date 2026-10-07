#if canImport(SwiftUI)
    import NardukMusicCore
    import SwiftUI

    // The four Canvas visualizers lifted from Data Beats' `LiveAudioViews.swift`. Each draws from a `SoundVisualState`
    // only (its smoothing, peak caps, pads and meters replace Data Beats' `SpectrumCaps`, `PadState` and `MeterState`),
    // and takes every series color from the state's palette. They draw no backdrop: the host supplies one.

    @MainActor extension SoundVisualizers {
        /// 64 log-spaced bands, additive glow, peak-hold caps and a faint reflection.
        static func spectrum(_ ctx: inout GraphicsContext, _ size: CGSize, _ s: SoundVisualState) {
            guard size.width > 40, size.height > 30 else { return }
            let bands = SoundVisualState.bandCount
            let live = !s.isSilent
            let t = s.time
            let baseline = size.height * 0.80
            let usable = baseline - 6
            let slot = (size.width - 8) / CGFloat(bands)
            let barWidth = max(1.5, slot * 0.68)
            let palette = s.palette
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [
                    SoundCanvas.color(palette.c1), SoundCanvas.color(palette.c0, 0.9), SoundCanvas.color(palette.c2),
                ]),
                startPoint: CGPoint(x: 0, y: baseline), endPoint: CGPoint(x: 0, y: 6))

            let spectrum = s.spectrum
            let peaks = s.peaks
            func value(_ i: Int) -> CGFloat {
                if live { return CGFloat(spectrum[i]) }
                return CGFloat(0.04 + 0.03 * sin(t * 1.3 + Double(i) * 0.3))
            }
            var bars = Path()
            var reflection = Path()
            var capPath = Path()
            for i in 0..<bands {
                let x = 4 + slot * CGFloat(i) + (slot - barWidth) / 2
                let h = max(1.5, usable * min(1, value(i)))
                bars.addRoundedRect(
                    in: CGRect(x: x, y: baseline - h, width: barWidth, height: h),
                    cornerSize: CGSize(width: 1, height: 1))
                reflection.addRect(CGRect(x: x, y: baseline + 3, width: barWidth, height: h * 0.28))
                let capH = usable * CGFloat(min(1, max(peaks[i], Float(value(i)))))
                capPath.addRect(CGRect(x: x, y: baseline - capH - 4, width: barWidth, height: 2))
            }
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: 7))
                layer.blendMode = .plusLighter
                layer.fill(bars, with: shading)
            }
            var additive = ctx
            additive.blendMode = .plusLighter
            additive.fill(bars, with: shading)
            additive.opacity = 0.16
            additive.fill(reflection, with: shading)
            ctx.soundGlowStroke(
                capPath, color: SoundCanvas.color(palette.c2), width: 1.5, glow: 0.4, opacity: 0.9, hot: 0.5,
                cap: .butt)
            var base = Path()
            base.move(to: CGPoint(x: 0, y: baseline + 1))
            base.addLine(to: CGPoint(x: size.width, y: baseline + 1))
            ctx.stroke(base, with: .color(Color.white.opacity(0.12)), lineWidth: 1)
        }

        /// The first rising zero crossing in the leading 128 samples, so the trace holds still; 0 when there is none.
        static func scopeTrigger(_ wave: UnsafeBufferPointer<Float>) -> Int {
            guard wave.count >= scopeWindow + 128 else { return 0 }
            for i in 1..<128 where wave[i - 1] < 0 && wave[i] >= 0 { return i }
            return 0
        }

        static let scopeWindow = 384

        /// The output waveform on a phosphor graticule, triggered on a rising zero crossing.
        static func scope(_ ctx: inout GraphicsContext, _ size: CGSize, _ s: SoundVisualState) {
            guard size.width > 40, size.height > 30 else { return }
            let midY = size.height / 2
            var grid = Path()
            for k in 1..<8 {
                let x = size.width * CGFloat(k) / 8
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            for k in 1..<4 {
                let y = size.height * CGFloat(k) / 4
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            ctx.stroke(grid, with: .color(Color.white.opacity(0.05)), lineWidth: 1)

            let wave = s.waveform
            let live = !s.isSilent
            let start = live ? scopeTrigger(wave) : 0
            let t = s.time
            var path = Path()
            for k in 0..<scopeWindow {
                let amp: Double
                if live, start + k < wave.count {
                    amp = Double(wave[start + k])
                } else {
                    amp = 0.06 * sin(t * 2.5 + Double(k) * 0.07)
                }
                let p = CGPoint(
                    x: size.width * CGFloat(k) / CGFloat(scopeWindow - 1),
                    y: midY - CGFloat(max(-1, min(1, amp))) * midY * 0.9)
                if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            ctx.soundGlowStroke(path, color: SoundCanvas.color(s.palette.c1), width: 1.8, glow: 1.3, hot: 0.6)
        }

        /// A dial: the needle is the wobble LFO phase, the arc fill is the filter cutoff; peak and RMS meters sit beside
        /// it.
        static func wobbleMeter(
            _ ctx: inout GraphicsContext, _ size: CGSize, _ s: SoundVisualState, _ style: SoundVisualizerStyle
        ) {
            guard size.width > 80, size.height > 60 else { return }
            let palette = s.palette
            let accent = SoundCanvas.color(palette.c1)
            let needleColor = SoundCanvas.color(palette.c2)
            let dialSide = min(size.height, size.width * 0.66)
            let center = CGPoint(x: dialSide / 2 + 4, y: size.height / 2)
            let radius = dialSide / 2 - 14
            let start = 0.75 * Double.pi
            let sweep = 1.5 * Double.pi
            let cutoff = Double(min(1, max(0, s.wobbleCutoff)))
            let phase = Double(s.wobblePhase)

            ctx.stroke(
                soundArcPath(center: center, radius: radius, from: start, to: start + sweep),
                with: .color(Color.white.opacity(0.10)), style: StrokeStyle(lineWidth: 8, lineCap: .round))
            if cutoff > 0.005 {
                ctx.soundGlowStroke(
                    soundArcPath(center: center, radius: radius, from: start, to: start + sweep * cutoff),
                    color: accent, width: 6, glow: 1.2, hot: 0.3)
            }
            var ticks = Path()
            for k in 0...10 {
                let a = start + sweep * Double(k) / 10
                ticks.move(
                    to: CGPoint(
                        x: center.x + (radius - 12) * CGFloat(cos(a)), y: center.y + (radius - 12) * CGFloat(sin(a))))
                ticks.addLine(
                    to: CGPoint(
                        x: center.x + (radius - 18) * CGFloat(cos(a)), y: center.y + (radius - 18) * CGFloat(sin(a))))
            }
            ctx.stroke(ticks, with: .color(Color.white.opacity(0.18)), lineWidth: 1)

            // The needle sweeps a full turn per LFO cycle, with a fading tail.
            let needleAngle = -Double.pi / 2 + phase * 2 * .pi
            for k in stride(from: 6, through: 0, by: -1) {
                let a = needleAngle - Double(k) * 0.07
                var tail = Path()
                tail.move(to: center)
                tail.addLine(
                    to: CGPoint(
                        x: center.x + (radius - 8) * CGFloat(cos(a)), y: center.y + (radius - 8) * CGFloat(sin(a))))
                if k == 0 {
                    ctx.soundGlowStroke(tail, color: needleColor, width: 2, glow: 1, hot: 0.6)
                } else {
                    var faint = ctx
                    faint.blendMode = .plusLighter
                    faint.stroke(tail, with: .color(needleColor.opacity(0.10 * Double(7 - k) / 7)), lineWidth: 2)
                }
            }
            ctx.soundGlowDot(
                CGPoint(
                    x: center.x + (radius - 8) * CGFloat(cos(needleAngle)),
                    y: center.y + (radius - 8) * CGFloat(sin(needleAngle))),
                radius: 3, color: needleColor)
            ctx.fill(soundCirclePath(center: center, radius: 5), with: .color(style.stage))
            ctx.draw(
                Text("WOBBLE").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(style.label),
                at: CGPoint(x: center.x, y: center.y + radius * 0.45), anchor: .center)
            ctx.draw(
                Text("cutoff \(Int((cutoff * 100).rounded()))%").font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(accent),
                at: CGPoint(x: center.x, y: center.y + radius * 0.65), anchor: .center)

            // Meters.
            let metersX = dialSide + 20
            let meterWidth = max(10, min(26, (size.width - metersX - 16) / 2.6))
            let top: CGFloat = 20
            let bottom = size.height - 26
            guard bottom - top > 20 else { return }
            let gradient = GraphicsContext.Shading.linearGradient(
                Gradient(stops: [
                    .init(color: SoundCanvas.color(palette.c2), location: 0),
                    .init(color: SoundCanvas.color(palette.c0), location: 0.6),
                    .init(color: SoundCanvas.color(palette.c1), location: 0.82),
                    .init(color: SoundCanvas.color(SoundCanvas.hot(palette.c1, 0.35)), location: 1),
                ]), startPoint: CGPoint(x: 0, y: bottom), endPoint: CGPoint(x: 0, y: top))
            let floorDB = Double(s.configuration.meterFloorDB)
            for index in 0..<2 {
                let entry = (index == 0 ? "PEAK" : "RMS", index == 0 ? s.peak : s.rms)
                let x = metersX + CGFloat(index) * (meterWidth + 14)
                let track = CGRect(x: x, y: top, width: meterWidth, height: bottom - top)
                ctx.fill(Path(roundedRect: track, cornerRadius: 3), with: .color(Color.white.opacity(0.07)))
                let h = track.height * CGFloat(entry.1)
                if h > 0.5 {
                    let fill = Path(
                        roundedRect: CGRect(x: x, y: bottom - h, width: meterWidth, height: h), cornerRadius: 3)
                    ctx.drawLayer { layer in
                        layer.addFilter(.blur(radius: 5))
                        layer.blendMode = .plusLighter
                        layer.opacity = 0.7
                        layer.fill(fill, with: gradient)
                    }
                    var additive = ctx
                    additive.blendMode = .plusLighter
                    additive.fill(fill, with: gradient)
                }
                if index == 0 {
                    let holdY = bottom - track.height * CGFloat(s.peakHold)
                    var cap = Path()
                    cap.move(to: CGPoint(x: x - 2, y: holdY))
                    cap.addLine(to: CGPoint(x: x + meterWidth + 2, y: holdY))
                    ctx.soundGlowStroke(
                        cap, color: SoundCanvas.color(palette.c1), width: 1.5, glow: 0.4, hot: 0.5, cap: .butt)
                }
                ctx.draw(
                    Text(entry.0).font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(style.label),
                    at: CGPoint(x: x + meterWidth / 2, y: top - 9), anchor: .center)
                let decibels = floorDB + entry.1 * -floorDB
                let label = entry.1 > 0.001 ? String(format: "%.0f", decibels) : "-\u{221E}"
                ctx.draw(
                    Text(label).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.white.opacity(0.8)),
                    at: CGPoint(x: x + meterWidth / 2, y: bottom + 12), anchor: .center)
            }
        }

        /// Where on the palette an instrument's pad sits: instruments of one role share a hue.
        static func padPosition(_ instrument: Instrument) -> Float {
            switch instrument {
            case .kick, .vox: 0
            case .snare, .scratch: 0.17
            case .hat, .openHat, .riser: 0.34
            case .wobble, .laser: 0.5
            case .sub, .keys: 0.67
            case .glitch, .tapeStop, .impact: 0.84
            case .acousticGuitar, .strum: 0.25
            case .electricGuitar, .electricStrum: 0.75
            case .bassGuitar: 0.58
            }
        }

        /// A pad label's font size: 12 pt, shrunk until the longest name fits its cell (monospaced glyphs are ~0.6 em).
        static func labelSize(_ characters: Int, cellWidth: CGFloat) -> CGFloat {
            min(12, max(6, (cellWidth - 8) / (0.6 * CGFloat(max(characters, 1)))))
        }

        /// One pad per instrument; each flashes when the instrument fires.
        static func pads(
            _ ctx: inout GraphicsContext, _ size: CGSize, _ s: SoundVisualState, _ style: SoundVisualizerStyle
        ) {
            let all = Instrument.allCases
            guard size.width > 60, size.height > 40 else { return }
            let columns = max(2, min(all.count, Int(size.width / 86)))
            let rows = (all.count + columns - 1) / columns
            let gap: CGFloat = 8
            let cellW = (size.width - gap * CGFloat(columns + 1)) / CGFloat(columns)
            let cellH = (size.height - gap * CGFloat(rows + 1)) / CGFloat(rows)
            let brightness = s.padBrightness
            for (index, instrument) in all.enumerated() {
                let col = index % columns
                let row = index / columns
                let rect = CGRect(
                    x: gap + CGFloat(col) * (cellW + gap), y: gap + CGFloat(row) * (cellH + gap), width: cellW,
                    height: cellH)
                let shape = Path(roundedRect: rect, cornerRadius: 8)
                let level = Double(brightness[instrument.index])
                let color = SoundCanvas.color(s.palette.sample(padPosition(instrument)))
                ctx.fill(shape, with: .color(Color.white.opacity(0.06)))
                var additive = ctx
                additive.blendMode = .plusLighter
                additive.fill(shape, with: .color(color.opacity(0.06 + 0.7 * level)))
                if level > 0.02 {
                    ctx.drawLayer { layer in
                        layer.addFilter(.blur(radius: 8))
                        layer.blendMode = .plusLighter
                        layer.stroke(shape, with: .color(color.opacity(level)), lineWidth: 4)
                    }
                }
                ctx.stroke(shape, with: .color(color.opacity(0.25 + 0.75 * level)), lineWidth: 1.2)
                ctx.draw(
                    Text(instrument.rawValue.uppercased())
                        .font(
                            .system(
                                size: labelSize(instrument.rawValue.count, cellWidth: cellW), weight: .bold,
                                design: .monospaced)
                        )
                        .foregroundStyle(level > 0.5 ? Color.white : color.opacity(0.85)),
                    at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
            }
        }
    }
#endif
