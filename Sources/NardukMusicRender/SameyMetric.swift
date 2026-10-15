import Foundation
import NardukMusicCore

extension MusicScenario {
    /// One song of the infinite queue, as a scenario: the seed picks tempo, key and mode inside the genre
    /// (`SongSettings.varied`) at the default variety, and the genre's default `SongRecipe` plan drives the energy,
    /// with a drop queued where each drop part starts. The A/B harness and the samey metric both play songs this way.
    public static func song(genre: Genre, seed: UInt64, variety: Double = SongSettings().variety) -> MusicScenario {
        let script = SongRecipe(title: genre.shortName, genre: genre, seed: seed).script()
        return MusicScenario(
            name: "\(genre.rawValue) seed \(seed)", seed: seed, genre: genre, family: genre.family, variety: variety,
            varied: true, seconds: script.seconds, signals: script.signals,
            actions: script.dropTimes.map { MusicScenario.Action(time: $0, queueDrop: true) })
    }

    /// The seconds at which the first drop is queued, if any.
    public var firstDropTime: Double? { actions?.filter { $0.queueDrop == true }.map(\.time).min() }
}

/// The notes a scenario's conductor writes, without the synth: the same 60 Hz virtual clock and 100 ms look-ahead as
/// `OfflineRenderer`, so it is cheap enough to read whole songs.
public struct NoteCapture: Sendable {
    public var settings: SongSettings
    public var notes: [ScheduledNote]
    /// The section the conductor was in at each bar.
    public var sections: [SongSection]
    public var seconds: Double

    public init(_ scenario: MusicScenario, seconds: Double? = nil) {
        let length = seconds ?? scenario.seconds ?? 30
        var conductor = DropConductor(settings: scenario.settings())
        if let build = scenario.buildThreshold {
            conductor.setThresholds(build: build, drop: scenario.dropThreshold ?? build * 0.7)
        }
        settings = conductor.settings
        var notes: [ScheduledNote] = []
        var sections: [Int: SongSection] = [:]
        var signals = scenario.timeline()[...]
        var actions = (scenario.actions ?? []).sorted { $0.time < $1.time }[...]
        var position = 0.0
        var scheduledThrough = -1
        let ticks = Int((length * OfflineRenderer.tickRate).rounded())
        for tick in 0..<ticks {
            let end = Double(tick + 1) / OfflineRenderer.tickRate
            while let action = actions.first, action.time < end {
                if let genre = action.genre { conductor.setGenre(genre) }
                if action.queueDrop == true { conductor.queueDrop() }
                actions = actions.dropFirst()
            }
            while let signal = signals.first, signal.time < end {
                conductor.ingest(signal)
                signals = signals.dropFirst()
            }
            let secondsPerStep = conductor.settings.secondsPerStep
            let through = Int(position + OfflineRenderer.lookaheadSeconds / secondsPerStep)
            if through > scheduledThrough {
                notes += conductor.advance(throughStep: through)
                scheduledThrough = through
                sections[through / max(1, settings.stepsPerBar)] = conductor.snapshot.section
            }
            position += 1 / OfflineRenderer.tickRate / secondsPerStep
        }
        self.notes = notes
        let bars = Int(position) / max(1, settings.stepsPerBar)
        var last = SongSection.intro
        self.sections = (0..<max(bars, 0)).map { bar in
            if let section = sections[bar] { last = section }
            return last
        }
        self.seconds = length
    }
}

/// One song's feature vector for the samey metric.
public struct TrackFeatures: Sendable, Hashable, Codable {
    public var genre: Genre
    public var seed: UInt64
    public var bpm: Double
    /// The form as run lengths in bars ("intro 4, build 4, drop 8").
    public var form: String
    /// Fraction of bars in each section, in `SongSection.allCases` order.
    public var sectionShares: [Double]
    public var instruments: [String]
    /// Conductor notes per second.
    public var noteDensity: Double
    /// Pitched notes per pitch class, C first, summing to 1 (all zeros when nothing is pitched).
    public var pitchClasses: [Double]
    /// The bass patch: the most used `voice` of the wobble, else sub, else bass guitar notes ("wobble:13").
    public var bassPatch: String
    /// The patch combination: each melodic instrument, with its most used `voice` for the patch-bank ones.
    public var patchCombination: String
    /// Bars that end a 4-bar group with a drum pattern different from the bar before it: a proxy for fills, since the
    /// conductor's fill choice is not public.
    public var fillBars: Int
    public var audio: AudioFeatures

    /// Instruments whose `voice` picks a patch from a bank.
    static let patchInstruments: Set<Instrument> = [.wobble, .sub, .keys, .bassGuitar]
    static let drums: Set<Instrument> = [.kick, .snare, .hat, .openHat]
    static let effects: Set<Instrument> = [.glitch, .scratch, .laser, .riser, .tapeStop, .impact, .cut]

    public init(genre: Genre, seed: UInt64, capture: NoteCapture, audio: AudioFeatures) {
        self.genre = genre
        self.seed = seed
        self.audio = audio
        bpm = capture.settings.bpm
        var runs: [(SongSection, Int)] = []
        for section in capture.sections {
            if let last = runs.last, last.0 == section {
                runs[runs.count - 1].1 += 1
            } else {
                runs.append((section, 1))
            }
        }
        form = runs.map { "\($0.0.rawValue) \($0.1)" }.joined(separator: ", ")
        let bars = Double(max(1, capture.sections.count))
        sectionShares = SongSection.allCases.map { section in
            Double(capture.sections.filter { $0 == section }.count) / bars
        }
        let notes = capture.notes
        instruments = Set(notes.map(\.instrument.rawValue)).sorted()
        noteDensity = Double(notes.count) / max(capture.seconds, 1e-9)
        var classes = [Double](repeating: 0, count: 12)
        for note in notes where !Self.drums.contains(note.instrument) {
            if let pitch = note.params.pitch { classes[((pitch % 12) + 12) % 12] += 1 }
        }
        let pitched = classes.reduce(0, +)
        pitchClasses = pitched > 0 ? classes.map { $0 / pitched } : classes
        func modalVoice(_ instrument: Instrument) -> Int? {
            var counts: [Int: Int] = [:]
            for note in notes where note.instrument == instrument { counts[note.params.voice ?? 0, default: 0] += 1 }
            return counts.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key
        }
        bassPatch =
            [Instrument.wobble, .sub, .bassGuitar].lazy.compactMap { instrument in
                modalVoice(instrument).map { "\(instrument.rawValue):\($0)" }
            }.first ?? "none"
        let melodic = Set(notes.map(\.instrument)).subtracting(Self.drums).subtracting(Self.effects)
        patchCombination = melodic.map { instrument in
            Self.patchInstruments.contains(instrument)
                ? "\(instrument.rawValue):\(modalVoice(instrument) ?? 0)" : instrument.rawValue
        }.sorted().joined(separator: " ")
        let stepsPerBar = max(1, capture.settings.stepsPerBar)
        var drumBars: [Int: Set<Int>] = [:]
        for note in notes where Self.drums.contains(note.instrument) {
            let code = (note.step % stepsPerBar) * 8 + (Instrument.allCases.firstIndex(of: note.instrument) ?? 0)
            drumBars[note.step / stepsPerBar, default: []].insert(code)
        }
        let barCount = capture.sections.count
        fillBars =
            stride(from: 3, to: barCount, by: 4).filter { bar in
                drumBars[bar, default: []] != drumBars[bar - 1, default: []]
            }.count
    }

    /// How different two songs are, 0 (identical features) ... 1: the mean of nine group distances, each scaled to
    /// 0 ... 1 by a fixed constant (never by the run's own spread, so baselines compare across runs).
    public static func distance(_ a: TrackFeatures, _ b: TrackFeatures) -> Double {
        let groups = groupDistances(a, b)
        // Summed in a fixed order: a dictionary's order changes between runs, and so would the last bit of the sum.
        return groupNames.reduce(0) { $0 + (groups[$1] ?? 0) } / Double(groupNames.count)
    }

    public static let groupNames = [
        "tempo", "form", "instruments", "density", "pitchClasses", "mfccMeans", "mfccSpread", "centroid", "flux",
    ]
    /// The fixed scales: a tempo gap of 40 BPM, a 2x density or centroid ratio, an MFCC (c1 ... c12) Euclidean gap of
    /// 20 in means and of 10 in standard deviations each count as fully different.
    public static let scales: [String: Double] = [
        "tempoBPM": 40, "densityOctaves": 1, "mfccMeans": 20, "mfccSpread": 10, "centroidOctaves": 1,
    ]

    public static func groupDistances(_ a: TrackFeatures, _ b: TrackFeatures) -> [String: Double] {
        func clamp(_ x: Double) -> Double { x.isFinite ? min(1, max(0, x)) : 1 }
        func l1(_ x: [Double], _ y: [Double]) -> Double { zip(x, y).reduce(0) { $0 + abs($1.0 - $1.1) } }
        func euclid(_ x: ArraySlice<Double>, _ y: ArraySlice<Double>) -> Double {
            zip(x, y).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }.squareRoot()
        }
        func octaves(_ x: Double, _ y: Double) -> Double {
            x <= 0 && y <= 0 ? 0 : (x <= 0 || y <= 0 ? 1 : log2(max(x, y) / min(x, y)))
        }
        let setA = Set(a.instruments)
        let setB = Set(b.instruments)
        let union = setA.union(setB).count
        let spreadA = a.audio.mfccVariances.map { $0.squareRoot() }
        let spreadB = b.audio.mfccVariances.map { $0.squareRoot() }
        let fluxScale = max(a.audio.flux, b.audio.flux)
        return [
            "tempo": clamp(abs(a.bpm - b.bpm) / scales["tempoBPM"]!),
            "form": clamp(l1(a.sectionShares, b.sectionShares) / 2),
            "instruments": union == 0 ? 0 : 1 - Double(setA.intersection(setB).count) / Double(union),
            "density": clamp(octaves(a.noteDensity, b.noteDensity) / scales["densityOctaves"]!),
            "pitchClasses": clamp(l1(a.pitchClasses, b.pitchClasses) / 2),
            "mfccMeans": clamp(
                euclid(a.audio.mfccMeans.dropFirst(), b.audio.mfccMeans.dropFirst()) / scales["mfccMeans"]!),
            "mfccSpread": clamp(euclid(spreadA.dropFirst(), spreadB.dropFirst()) / scales["mfccSpread"]!),
            "centroid": clamp(octaves(a.audio.centroid, b.audio.centroid) / scales["centroidOctaves"]!),
            "flux": fluxScale > 0 ? clamp(abs(a.audio.flux - b.audio.flux) / fluxScale) : 0,
        ]
    }
}

/// The samey report for one genre's songs.
public struct SameyReport: Sendable, Hashable, Codable {
    public struct Tempo: Sendable, Hashable, Codable {
        public var min: Double
        public var max: Double
        public var spread: Double
        public var standardDeviation: Double
    }

    public var genre: Genre
    public var tracks: Int
    /// The mean, over songs, of each song's distance to its nearest other song. Higher is less samey.
    public var meanNearestNeighbour: Double
    public var minNearestNeighbour: Double
    /// The two seeds closest to each other (worth a listen).
    public var closestPair: [UInt64]
    /// Clusters when songs closer than `threshold` join (single linkage). Equal to `tracks` when no two are that close.
    public var threshold: Double
    public var clusters: Int
    public var largestCluster: Int
    public var distinctBassPatches: Int
    public var distinctPatchCombinations: Int
    public var distinctForms: Int
    public var meanFillBarsPerTrack: Double
    public var tempo: Tempo
    /// Each group's mean distance to the nearest neighbour's, to show which axes are samey.
    public var meanNearestGroupDistances: [String: Double]
    public var features: [TrackFeatures]

    public init(genre: Genre, features: [TrackFeatures], threshold: Double) {
        self.genre = genre
        self.features = features
        self.threshold = threshold
        tracks = features.count
        let n = features.count
        var distance = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in (i + 1)..<max(n, i + 1) {
                let d = TrackFeatures.distance(features[i], features[j])
                distance[i][j] = d
                distance[j][i] = d
            }
        }
        var nearest: [Int] = []
        var nearestDistance: [Double] = []
        for i in 0..<n {
            let others = (0..<n).filter { $0 != i }
            let j = others.min { distance[i][$0] < distance[i][$1] } ?? i
            nearest.append(j)
            nearestDistance.append(n > 1 ? distance[i][j] : 0)
        }
        meanNearestNeighbour = n > 0 ? nearestDistance.reduce(0, +) / Double(n) : 0
        minNearestNeighbour = nearestDistance.min() ?? 0
        if let best = nearestDistance.indices.min(by: { nearestDistance[$0] < nearestDistance[$1] }), n > 1 {
            closestPair = [features[best].seed, features[nearest[best]].seed].sorted()
        } else {
            closestPair = []
        }
        var groups = Dictionary(uniqueKeysWithValues: TrackFeatures.groupNames.map { ($0, 0.0) })
        if n > 1 {
            for i in 0..<n {
                for (name, value) in TrackFeatures.groupDistances(features[i], features[nearest[i]]) {
                    groups[name, default: 0] += value / Double(n)
                }
            }
        }
        meanNearestGroupDistances = groups
        // Single-linkage clusters by union-find.
        var parent = Array(0..<n)
        func root(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        for i in 0..<n {
            for j in (i + 1)..<max(n, i + 1) where distance[i][j] < threshold { parent[root(i)] = root(j) }
        }
        var sizes: [Int: Int] = [:]
        for i in 0..<n { sizes[root(i), default: 0] += 1 }
        clusters = sizes.count
        largestCluster = sizes.values.max() ?? 0
        distinctBassPatches = Set(features.map(\.bassPatch)).count
        distinctPatchCombinations = Set(features.map(\.patchCombination)).count
        distinctForms = Set(features.map(\.form)).count
        meanFillBarsPerTrack = n > 0 ? Double(features.map(\.fillBars).reduce(0, +)) / Double(n) : 0
        let bpms = features.map(\.bpm)
        let mean = n > 0 ? bpms.reduce(0, +) / Double(n) : 0
        let variance = n > 0 ? bpms.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(n) : 0
        tempo = Tempo(
            min: bpms.min() ?? 0, max: bpms.max() ?? 0, spread: (bpms.max() ?? 0) - (bpms.min() ?? 0),
            standardDeviation: variance.squareRoot())
    }
}

/// Writes songs per genre offline and measures how alike they are (narduk-sound#36).
public enum SameyMetric {
    /// Where in each song the timbre features are read: the render covers `0 ..< end` and the features read
    /// `start ..< end` (the late build into the first drop, for the default plan).
    public struct AudioWindow: Sendable, Hashable, Codable {
        public var start: Double
        public var end: Double

        public init(start: Double = 24, end: Double = 36) {
            self.start = start
            self.end = end
        }
    }

    /// The features of one song.
    public static func features(genre: Genre, seed: UInt64, window: AudioWindow = AudioWindow()) -> TrackFeatures {
        let scenario = MusicScenario.song(genre: genre, seed: seed)
        let capture = NoteCapture(scenario)
        let end = min(window.end, scenario.seconds ?? window.end)
        let audio = OfflineRenderer.render(scenario, seconds: end)
        let from = min(Int(window.start * audio.sampleRate), audio.frameCount)
        let mono = (from..<audio.frameCount).map { (audio.left[$0] + audio.right[$0]) * 0.5 }
        return TrackFeatures(
            genre: genre, seed: seed, capture: capture,
            audio: AudioFeatures.measure(mono, sampleRate: audio.sampleRate))
    }
}
