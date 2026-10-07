import Foundation
import NardukMusicCore
import Testing

@testable import NardukMusicCritic

/// The verdict: thresholds, determinism, and the cost of judging a song in every genre.
@Suite struct SongVerdictTests {
    static func report(clicks: Int = 0, rmsDB: Double = -12, drumMs: Double = 0.1) -> AudioReport {
        AudioReport(
            seconds: 120, clippedSamples: 0, clicks: clicks, clickTimes: [], silenceGaps: 0, longestSilence: 0,
            rmsDB: rmsDB, loudestSecondDB: rmsDB + 3, peakDB: -1,
            drums: .init(
                measured: 100, unmeasured: 0, worstOffsetMs: drumMs, meanOffsetMs: drumMs / 2, worstAt: 30,
                maxSwingMs: 0),
            cost: .init(
                blocks: 100, budgetMs: 16.7, worstMs: 30, meanMs: 1, overBudget: 2, worstAt: 3, worstPumpMs: 0.1))
    }

    static let good = SongScore(melody: 0.6, repetition: 0.65, arc: 0.9, events: 0.7, seconds: 120, total: 65)

    @Test func aCleanGoodSongIsKept() {
        let verdict = SongVerdict(score: Self.good, audio: Self.report())
        #expect(verdict.keep)
        #expect(verdict.reasons.isEmpty)
        #expect(verdict.notes.isEmpty)
    }

    @Test func repetitionIsReportedButNeverDropsASong() {
        // A loop song: the hook repeats bar for bar, so repetition is 0 and the four-part total is low.
        let loop = SongScore(
            melody: 0.6, repetition: 0, arc: 0.9, events: 0.7, seconds: 120,
            total: SongScore.total(melody: 0.6, repetition: 0, arc: 0.9, events: 0.7))
        #expect(loop.total < 44)
        #expect(loop.totalWithoutRepetition == Self.good.totalWithoutRepetition)
        var thresholds = SongVerdict.Thresholds()
        thresholds.minPart = 0.5
        let verdict = SongVerdict(score: loop, audio: Self.report(), thresholds: thresholds)
        #expect(verdict.keep, "\(verdict.reasons)")
        #expect(verdict.notes == ["repetition 0.00 is the weakest part (reported, not judged)"])
    }

    @Test func eachLimitGivesItsReason() {
        var weak = Self.good
        weak.melody = 0.05
        let verdict = SongVerdict(score: weak, audio: Self.report(clicks: 3, rmsDB: -40, drumMs: 12))
        #expect(!verdict.keep)
        #expect(verdict.reasons.count == 4, "\(verdict.reasons)")
        #expect(verdict.reasons.contains("score 23 (without repetition) under 44"))
        #expect(verdict.reasons.contains("3 clicks"))
        #expect(verdict.reasons.contains { $0.hasPrefix("too quiet") })
        #expect(verdict.reasons.contains { $0.hasPrefix("drums off by 12.0 ms") })
    }

    @Test func nilSwitchesAnLimitOffAndOptInLimitsApply() {
        var thresholds = SongVerdict.Thresholds()
        thresholds.maxClicks = nil
        #expect(SongVerdict(score: Self.good, audio: Self.report(clicks: 9), thresholds: thresholds).keep)
        thresholds.maxOverBudgetShare = 0.01
        thresholds.minPart = 0.65
        let verdict = SongVerdict(score: Self.good, audio: Self.report(), thresholds: thresholds)
        #expect(verdict.reasons == ["melody 0.60 under 0.65", "2 of 100 blocks over budget (worst 30.0 ms)"])
    }

    @Test func aJudgedSongIsTheSameEveryTime() {
        let settings = SongSettings(genre: .trap, seed: 3)
        let first = AudioCheck.render(settings: settings, seconds: 5)
        let second = AudioCheck.render(settings: settings, seconds: 5)
        #expect(first.audio.fingerprint == second.audio.fingerprint)
        #expect(first.notes == second.notes && first.sections == second.sections && first.energy == second.energy)
        var a = first.report
        var b = second.report
        a.cost = nil  // wall time is the one measurement that is not deterministic
        b.cost = nil
        #expect(a == b)
        let verdict = SongCritic.judge(settings: settings, seconds: 5)
        #expect(verdict.score.seconds > 3, "two whole bars of five seconds at 140 BPM")
        #expect(verdict.audio.clippedSamples == first.report.clippedSamples)
    }

    #if DEBUG
        /// A debug build renders far slower than real time (about 76 s for a two-minute song), so here each genre
        /// scores its notes only; the release run below judges the whole song.
        static let budgetSeconds = 1.0
    #else
        /// Measured 2026-10-07 on a Mac15,10 MacBook Pro, release, one test at a time: 1.74 ... 2.64 s a genre for
        /// two minutes (two renders and the meters). The bound leaves room for a loaded machine.
        static let budgetSeconds = 8.0
    #endif

    @Test(arguments: Genre.allCases)
    func aTwoMinuteSongIsScoredInTime(genre: Genre) {
        let settings = SongSettings(bpm: genre.defaultBPM, genre: genre, seed: 3)
        let start = Date()
        #if DEBUG
            let bars = Int((120 / (settings.secondsPerStep * 16)).rounded())
            let score = SongCritic.score(settings: settings, bars: bars)
            #expect(score.total > 0)
        #else
            let verdict = SongCritic.judge(settings: settings, seconds: 120)
            #expect(verdict.score.total > 0)
            #expect(verdict.audio.clippedSamples == 0)
        #endif
        let elapsed = Date().timeIntervalSince(start)
        print("\(genre): scored a two-minute song in \(String(format: "%.2f", elapsed)) s")
        #expect(elapsed < Self.budgetSeconds, "\(genre): \(elapsed) s")
    }
}

/// Prints the verdict table for every genre (seed 3, three minutes). Set `NARDUK_CRITIC_TABLE=1` and run in release;
/// `NARDUK_CRITIC_SECONDS` changes the length and `NARDUK_CRITIC_GENRES=dubstep,lofi` picks genres.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["NARDUK_CRITIC_TABLE"] != nil))
struct SongVerdictTable {
    @Test func table() {
        let seconds = Double(ProcessInfo.processInfo.environment["NARDUK_CRITIC_SECONDS"] ?? "") ?? 180
        print(
            "| Genre | Total | Judged (no repetition) | Weakest | Clips | Clicks | Worst drum ms | Worst render ms | Keep"
                + " | Reasons |")
        print("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
        let only = ProcessInfo.processInfo.environment["NARDUK_CRITIC_GENRES"]?.split(separator: ",").map(String.init)
        for genre in Genre.allCases where only?.contains(genre.rawValue) ?? true {
            let settings = SongSettings(bpm: genre.defaultBPM, genre: genre, seed: 3)
            let start = Date()
            let verdict = SongCritic.judge(settings: settings, seconds: seconds)
            let elapsed = Date().timeIntervalSince(start)
            let audio = verdict.audio
            let cells = [
                genre.rawValue, String(Int(verdict.score.total)), String(Int(verdict.score.totalWithoutRepetition)),
                verdict.score.weakest, String(audio.clippedSamples),
                String(audio.clicks), String(format: "%.2f", audio.drums?.worstOffsetMs ?? -1),
                String(format: "%.1f at %.0f s", audio.cost?.worstMs ?? -1, audio.cost?.worstAt ?? -1),
                verdict.keep ? "yes" : "no",
                verdict.reasons.joined(separator: "; ") + String(format: " (judged in %.1f s)", elapsed),
            ]
            print("| " + cells.joined(separator: " | ") + " |")
        }
    }
}
