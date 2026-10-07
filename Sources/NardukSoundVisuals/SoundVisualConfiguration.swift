/// The constants Data Beats and Wirewatcher disagree on, so porting either onto `SoundVisualState` does not change
/// its look (docs/sound-contract.md section 3). Defaults are Wirewatcher's, the state's source of truth.
public struct SoundVisualConfiguration: Sendable, Equatable {
    /// A rate (per second) so high that smoothing is a no-op: `min(1, dt * rate)` is 1 at any real frame time.
    public static let passthroughRate: Float = 1_000

    /// Spectrum smoothing, per second, toward a higher (attack) or lower (release) value. This is a second stage:
    /// `SpectrumAnalyzer` already smooths each analysis (gap G13).
    public var spectrumAttack: Float = 34
    public var spectrumRelease: Float = 8
    /// The same in calm mode.
    public var calmSpectrumAttack: Float = 10
    public var calmSpectrumRelease: Float = 3.5

    /// Peak caps on the spectrum: hold (seconds) before falling, then fall rate (per second).
    public var capHold: Float = 0.4
    public var capFall: Float = 0.55

    /// Instrument pad flash decay: brightness *= exp(-dt * padDecay).
    public var padDecay: Float = 4.5

    /// `level` maps rmsDB over `levelFloorDB ... 0` onto 0 ... 1.
    public var levelFloorDB: Float = -48
    /// The meters map dB over `meterFloorDB ... 0`, fall at these rates (per second) and hold the peak tick.
    public var meterFloorDB: Float = -60
    public var meterPeakFall: Double = 1.2
    public var meterRMSFall: Double = 0.9
    public var meterHoldTime: Double = 0.8
    public var meterHoldFall: Double = 0.5

    /// Particles in the fixed pool.
    public var particleCapacity = 320

    public init() {}

    /// Wirewatcher's look (the default).
    public static var wirewatcher: SoundVisualConfiguration { SoundVisualConfiguration() }

    /// Data Beats' look: it draws the analyzer's output without a second smoothing stage, with its own cap and meter
    /// constants.
    public static var dataBeats: SoundVisualConfiguration {
        var c = SoundVisualConfiguration()
        c.spectrumAttack = passthroughRate
        c.spectrumRelease = passthroughRate
        c.calmSpectrumAttack = passthroughRate
        c.calmSpectrumRelease = passthroughRate
        c.capHold = 0.45
        c.capFall = 0.9
        return c
    }
}

/// What the stage should do beyond the signal itself.
public struct SoundVisualOptions: Sendable, Equatable {
    /// Calm (Reduce Motion): gates flash, shake, chroma, glitch and the particle spawners; slower smoothing.
    public var calm = false
    /// A generic 0 ... 1 external drive: Wirewatcher's smoothed traffic intensity, an iPad's motion, a data rate.
    /// It sets how wild the stage is (travel, saturation, shake, particle counts). nil means "as wild as the music's
    /// energy" (or, with no `MusicContext`, as loud as the signal).
    public var drive: Float?

    public init(calm: Bool = false, drive: Float? = nil) {
        self.calm = calm
        self.drive = drive
    }
}
