import NardukSoundAnalysis
import NardukSoundVisuals
import SwiftUI
import Testing

/// Logan: "i see new color controls but the visualizers dont seem to respect them in the sound gallery". The library
/// tests check each kind alone; these drive the gallery's own model and check what a card actually receives.
@MainActor @Suite struct PaletteLookTests {
    /// Advances a state `seconds` at 60 Hz, as a gallery timeline does (a stopped or paused one too: silence in).
    static func pump(_ state: SoundVisualState, seconds: Double = 1, from start: Double = 100) {
        var now = start
        for _ in 0..<Int(seconds * 60) {
            state.update(SoundVisualInput(frame: SoundFrame()), now: now)
            now += 1.0 / 60
        }
    }

    @Test func aNewLookReachesTheSharedStateAndEveryTilesOwnState() {
        let model = GalleryModel()
        let tileState = SoundVisualState()
        model.sync(tileState)
        #expect(tileState.look.isNeutral)
        Self.pump(tileState, seconds: 0.2)
        let before = tileState.palette
        model.choose(.ocean)
        model.sync(tileState)
        #expect(model.repaintHold, "a color change must keep a stopped or paused gallery drawing")
        #expect(model.visualState.look == model.look)
        #expect(tileState.look == model.look)
        Self.pump(tileState, from: 101)
        Self.pump(model.visualState, from: 101)
        #expect(tileState.palette != before, "a tile's own state ignored the look")
        #expect(model.visualState.palette == tileState.palette)

        model.look.hueShift = 90
        model.sync(tileState)
        #expect(tileState.look.hueShift == 90)

        model.rollRandom(seed: 5)
        model.sync(tileState)
        Self.pump(tileState, from: 103)
        Self.pump(model.visualState, from: 103)
        #expect(tileState.palette == model.visualState.palette)
        model.resetLook()
        model.sync(tileState)
        #expect(tileState.look.isNeutral)
    }
}
