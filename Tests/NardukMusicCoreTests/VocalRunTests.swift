import NardukMusicCore
import Testing

/// The vocal run ornament (narduk-libs#1641): a held note that holds, then sings a scale.
@Suite struct VocalRunTests {
    @Test func aRunHoldsThenClimbsTheScaleOnTheGrid() {
        let run = VocalRun(shape: .up, scale: .minorPentatonic, octaves: 1, fast: false, hold: 0.25)
        let steps = run.steps(root: 60, lengthSteps: 16)
        #expect(steps.first == VocalRun.Step(half: 0, pitch: 60, halves: 8, accent: 1))
        // Sixteenths: a step (two halves) apart, from the end of the hold to the end of the note.
        let notes = steps.dropFirst()
        #expect(notes.map(\.half) == Array(stride(from: 8, to: 32, by: 2)))
        #expect(notes.first?.pitch == 60 && notes.last?.pitch == 72)
        #expect(steps.map(\.halves).reduce(0, +) == 32, "the notes tile the held note exactly")
        let tones = Set([0, 3, 5, 7, 10, 12])
        #expect(notes.allSatisfy { tones.contains($0.pitch - 60) })
        #expect(zip(notes, notes.dropFirst()).allSatisfy { $0.pitch <= $1.pitch })
    }

    @Test func thirtySecondsDoubleTheNotesAndShapesTurnBack() {
        let slow = VocalRun(shape: .updown, fast: false, hold: 0).steps(root: 64, lengthSteps: 8)
        let fast = VocalRun(shape: .updown, fast: true, hold: 0).steps(root: 64, lengthSteps: 8)
        #expect(fast.count == slow.count * 2)
        let top = fast.map(\.pitch).max() ?? 0
        #expect(top - 64 >= 12, "an octave or more: \(top)")
        #expect(fast.first?.pitch == 64 && fast.last?.pitch == 64, "up and down returns to the root")
        let down = VocalRun(shape: .down, hold: 0).steps(root: 64, lengthSteps: 8)
        #expect(down.first!.pitch > down.last!.pitch)
        let wave = VocalRun(shape: .wave, hold: 0).steps(root: 64, lengthSteps: 16).map(\.pitch)
        let peaks = zip(wave.dropFirst(), zip(wave, wave.dropFirst(2))).filter { $0 > $1.0 && $0 > $1.1 }.count
        #expect(peaks >= 1)
    }

    @Test func aShortNoteStillGetsAWellFormedRun() {
        for length in 1...3 {
            let steps = VocalRun(fast: true, hold: 0.9).steps(root: 60, lengthSteps: length)
            #expect(
                !steps.isEmpty && steps.map(\.halves).reduce(0, +) == length * 2 && steps.allSatisfy { $0.halves >= 1 })
        }
    }
}
