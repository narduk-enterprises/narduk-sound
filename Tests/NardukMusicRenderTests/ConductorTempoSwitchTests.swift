import NardukMusicCore
import NardukMusicRender
import Testing

/// A conductor-driven offline render follows `DropConductor.lastSwitch`: a genre switch changes the tempo on the switch
/// bar itself, not a bar later.
@Suite struct ConductorTempoSwitchTests {
    /// Ticks (1/60 s) one bar lasts at `bpm`.
    static func barTicks(_ bpm: Double) -> Double { 16 * 15 / bpm * OfflineRenderer.tickRate }

    @Test func aConductorDrivenRenderChangesTempoAtTheSwitchBar() throws {
        let renderer = OfflineRenderer(settings: SongSettings(genre: .dubstep))
        var firstTick: [Int: Int] = [:]
        for tick in 0..<(60 * 10) {
            if tick == 60 * 3 { renderer.setGenre(.drumAndBass) }
            _ = renderer.advance()
            if firstTick[renderer.currentStep] == nil { firstTick[renderer.currentStep] = tick }
        }
        let change = try #require(renderer.withConductor { $0.lastSwitch })
        #expect(change.genre == .drumAndBass && change.bpm == 174 && change.step % 16 == 0)
        #expect(renderer.settings.bpm == 174 && renderer.settings.genre == .drumAndBass)

        /// How many ticks the bar starting at `step` was audible for.
        func ticks(barAt step: Int) throws -> Double {
            let start = try #require(firstTick[step], "step \(step) never sounded")
            let end = try #require(firstTick[step + 16], "step \(step + 16) never sounded")
            return Double(end - start)
        }
        let before = try ticks(barAt: change.step - 16)
        let after = try ticks(barAt: change.step + 16)
        #expect(abs(before - Self.barTicks(140)) <= 2, "the bar before the switch lasted \(before) ticks")
        #expect(abs(after - Self.barTicks(174)) <= 2, "the bar after the switch bar lasted \(after) ticks")

        let switchBar = try ticks(barAt: change.step)
        #expect(abs(switchBar - Self.barTicks(174)) <= 2, "the switch bar lasted \(switchBar) ticks")
    }
}
