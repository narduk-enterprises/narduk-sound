import Foundation
import NardukMusicCore
import NardukMusicDSP

/// A built-in pattern provider for previews and manual listening when no conductor
/// exists: an 8-bar cycle (2-bar build into a looping 2-bar wobble drop) from
/// `DemoPattern`, with the section echoed into the engine's frames.
@MainActor public final class DropEngineDemo {
    private var cursor = -1

    public init() {}

    /// Notes for every step after the last call, up to `throughStep`.
    public func notes(through throughStep: Int) -> [ScheduledNote] {
        if throughStep < cursor { cursor = -1 }  // the engine restarted from step 0
        guard throughStep > cursor else { return [] }
        let notes = DemoPattern.notes(in: (cursor + 1)...throughStep)
        cursor = throughStep
        return notes
    }

    /// Makes `engine` play the demo loop (call `engine.start()` afterwards).
    public static func attach(to engine: DropEngine) -> DropEngineDemo {
        let demo = DropEngineDemo()
        engine.noteProvider = { [weak engine] throughStep in
            if let engine { engine.section = DemoPattern.section(atStep: engine.currentStep) }
            return demo.notes(through: throughStep)
        }
        return demo
    }
}

extension DropEngine {
    /// Starts the built-in demo loop.
    public func playDemo() throws {
        _ = DropEngineDemo.attach(to: self)
        try start()
    }
}
