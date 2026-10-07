import NardukSoundVisuals
import SwiftUI

/// The palette bar: a preset picker, a 🎲 random roll, hue / saturation / brightness sliders and a hue-cycle toggle.
/// Every visualizer card changes at once, because they all draw from the shared state's palette.
struct PaletteControls: View {
    @Bindable var model: GalleryModel
    @State private var open = false

    private var cycling: Binding<Bool> {
        Binding(get: { model.look.cycle != 0 }, set: { model.look.cycle = $0 ? 24 : 0 })
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Picker("Palette", selection: presetSelection) {
                    if model.preset == nil { Text("Random").tag(Optional<SoundPalettePreset>.none) }
                    ForEach(SoundPalettePreset.allCases) { Text($0.title).tag(Optional($0)) }
                }
                .labelsHidden()
                Button("🎲 Random") { model.rollRandom() }
                Toggle("Cycle", isOn: cycling).toggleStyle(.button)
                Button(open ? "Less" : "Knobs") { open.toggle() }
                Button("Reset") { model.resetLook() }.disabled(model.look.isNeutral)
                Spacer(minLength: 0)
            }
            if open {
                slider("Hue", $model.look.hueShift, -180...180)
                slider("Saturation", $model.look.saturation, 0...2)
                slider("Brightness", $model.look.brightness, 0...2)
            }
        }
    }

    private var presetSelection: Binding<SoundPalettePreset?> {
        Binding(get: { model.preset }, set: { if let preset = $0 { model.choose(preset) } })
    }

    private func slider(_ title: String, _ value: Binding<Float>, _ range: ClosedRange<Float>) -> some View {
        HStack {
            Text(title).font(.footnote).frame(width: 80, alignment: .leading)
            Slider(value: value, in: range)
        }
    }
}
