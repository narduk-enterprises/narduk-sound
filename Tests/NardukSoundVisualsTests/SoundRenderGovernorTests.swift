import Testing

@testable import NardukSoundVisuals

/// Feeds `seconds` of frames at `gpuMs` each, 60 a second, and returns the governor after them.
private func run(_ governor: SoundRenderGovernor, gpuMs: Double, seconds: Double, from start: Double = 0)
    -> SoundRenderGovernor
{
    var g = governor
    var t = start
    while t < start + seconds {
        _ = g.observe(gpuMs: gpuMs, at: t)
        t += 1.0 / 60
    }
    return g
}

@Test func aFastGPUStaysAtFullQuality() {
    let g = run(SoundRenderGovernor(), gpuMs: 4, seconds: 10)
    #expect(g.scale == SoundRenderGovernor.maxScale)
    #expect(!g.halfRate)
}

@Test func aSlowLightShrinksUntilItFitsTheBudget() {
    // 30ms at 0.75 is about 4.8ms per 0.1 of scale squared: it needs about 0.5 to fit 16.7ms.
    var g = SoundRenderGovernor()
    var t = 0.0
    for _ in 0..<40 {
        let cost = 30 * (g.scale / 0.75) * (g.scale / 0.75)
        g = run(g, gpuMs: cost, seconds: 0.5, from: t)
        t += 0.5
    }
    #expect(g.scale < 0.75 && g.scale >= 0.4)
    #expect(!g.halfRate)
}

@Test func aVerySlowLightBottomsOutThenHalvesItsRate() {
    let g = run(SoundRenderGovernor(), gpuMs: 300, seconds: 5)
    #expect(g.scale == SoundRenderGovernor.minScale)
    #expect(g.halfRate)
}

@Test func headroomBringsTheRateBackThenTheSharpness() {
    var g = run(SoundRenderGovernor(), gpuMs: 300, seconds: 5)
    g = run(g, gpuMs: 3, seconds: 1, from: 5)
    #expect(!g.halfRate)
    g = run(g, gpuMs: 3, seconds: 10, from: 6)
    #expect(g.scale == SoundRenderGovernor.maxScale)
}
