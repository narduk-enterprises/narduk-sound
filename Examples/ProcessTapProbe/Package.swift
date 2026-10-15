// swift-tools-version: 6.2
import Foundation
import PackageDescription

// The library package's identity is its directory name (narduk-sound, or a worktree's name).
let library = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().lastPathComponent

// A tiny command-line probe for NardukSoundAnalysis.ProcessTapSource (macOS 14.2+). It is a separate package so the
// library's gate and CI never build or run it: `swift test` runs under xctest, and the system-audio permission
// prompt must be attributed to a process a person can approve by name. Run it from the repository root:
//
//     swift run --package-path Examples/ProcessTapProbe process-tap-probe list
//     swift run --package-path Examples/ProcessTapProbe process-tap-probe music --pid $(pgrep -x Music) --seconds 20
//     swift run --package-path Examples/ProcessTapProbe process-tap-probe click --out /tmp/click.wav
let package = Package(
    name: "ProcessTapProbe",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(
            name: "process-tap-probe", dependencies: [.product(name: "NardukSoundAnalysis", package: library)],
            path: "Sources/ProcessTapProbe")
    ],
    swiftLanguageModes: [.v6]
)
