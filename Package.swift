// swift-tools-version: 6.2
import PackageDescription

// NardukSound: signals in, music out, and any audio in, pictures out. Core (the conductor), DSP (the synth), Render
// (offline PCM, WAV), SoundAnalysis, Sonify and SoundVisuals need only Foundation and Synchronization, so they build
// and test on the Linux gate; the real-time AVAudioEngine player is Darwin-only below. The contract is
// docs/sound-contract.md.
let package = Package(
    name: "narduk-sound",
    platforms: [.macOS(.v15), .iOS(.v18), .tvOS(.v18), .watchOS(.v11), .visionOS(.v2)],
    products: [
        .library(name: "NardukMusicCore", targets: ["NardukMusicCore"]),
        .library(name: "NardukMusicDSP", targets: ["NardukMusicDSP"]),
        .library(name: "NardukMusicRender", targets: ["NardukMusicRender"]),
        .library(name: "NardukSoundAnalysis", targets: ["NardukSoundAnalysis"]),
        .library(name: "NardukSonify", targets: ["NardukSonify"]),
        .library(name: "NardukSoundVisuals", targets: ["NardukSoundVisuals"]),
        .executable(name: "narduk-music", targets: ["narduk-music"]),
    ],
    targets: [
        .target(name: "NardukMusicCore"),
        .target(
            name: "NardukMusicDSP", dependencies: ["NardukMusicCore", "NardukSoundAnalysis"],
            // Copied entry by entry, not as one `Resources` folder: an iOS bundle is flat, and a `Resources` directory
            // inside one makes codesign reject it ("bundle format unrecognized"), so no iOS app could link
            // NardukMusicDSP.
            resources: [.copy("Resources/vocalsamples.bin"), .copy("Resources/LICENSES")]
        ),
        .target(name: "NardukMusicRender", dependencies: ["NardukMusicCore", "NardukMusicDSP"]),
        .executableTarget(name: "narduk-music", dependencies: ["NardukMusicRender"]),
        .target(name: "NardukSoundAnalysis"),
        .target(name: "NardukSonify", dependencies: ["NardukMusicCore"]),
        .target(name: "NardukSoundVisuals", dependencies: ["NardukSoundAnalysis", "NardukMusicCore"]),
        .testTarget(name: "NardukMusicCoreTests", dependencies: ["NardukMusicCore", "NardukMusicDSP"]),
        .testTarget(name: "NardukMusicDSPTests", dependencies: ["NardukMusicCore", "NardukMusicDSP"]),
        .testTarget(
            name: "NardukMusicRenderTests",
            dependencies: ["NardukMusicCore", "NardukMusicDSP", "NardukMusicRender"]
        ),
        .testTarget(name: "NardukSoundAnalysisTests", dependencies: ["NardukSoundAnalysis"]),
        .testTarget(name: "NardukSonifyTests", dependencies: ["NardukSonify", "NardukMusicCore"]),
        .testTarget(
            name: "NardukSoundVisualsTests",
            dependencies: ["NardukSoundVisuals", "NardukSoundAnalysis", "NardukMusicCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)

// The real-time player: AVAudioEngine, an AVAudioSourceNode and an AAC recorder.
#if canImport(Darwin)
    package.products.append(.library(name: "NardukMusicEngine", targets: ["NardukMusicEngine"]))
    package.targets += [
        .target(name: "NardukMusicEngine", dependencies: ["NardukMusicCore", "NardukMusicDSP", "NardukSoundAnalysis"]),
        .testTarget(name: "NardukMusicEngineTests", dependencies: ["NardukMusicEngine"]),
    ]
#endif
