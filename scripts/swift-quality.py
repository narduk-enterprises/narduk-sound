"""NardukSound checks, the CLI, and a clean consumer resolving a real version tag in an isolated Git fixture."""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# The fixture tags its own copy with this version; it need not exist upstream.
VERSION = "0.5.0"
DARWIN = sys.platform == "darwin"
BUILD_FLAGS = ["-Xswiftc", "-use-ld=lld"] if sys.platform == "linux" else []
SCENARIO = ROOT / "scenarios/build-session.json"

# Renders one second offline and writes a WAV: the Linux-buildable products.
CONSUMER = """import Foundation
import NardukMusicCore
import NardukMusicRender

let scenario = try MusicScenario.load(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
let audio = OfflineRenderer.render(scenario, seconds: 1)
precondition(audio.frameCount == 48_000 && audio.peak > 0, "silent render")
let out = URL(fileURLWithPath: CommandLine.arguments[2])
try AudioFileWriter.writeWAV(audio, to: out)
print("Consumer rendered \\(audio.frameCount) frames, peak \\(audio.peak), to \\(out.lastPathComponent)")
"""


def run(*args: str, cwd: Path = ROOT) -> None:
    subprocess.run(args, cwd=cwd, check=True)


def readme_example() -> str:
    """The README's adapter example, compiled by the Apple consumer so it cannot rot."""
    readme = (ROOT / "README.md").read_text()
    section = readme.split("## Make your own source", 1)[1]
    match = re.search(r"```swift\n(.*?)```", section, re.S)
    assert match, "README.md has no Swift example under 'Make your own source'"
    return match.group(1)


def lint() -> None:
    run("swift", "format", "lint", "--strict", "--recursive", "Package.swift", "Sources", "Tests")
    swiftlint = shutil.which("swiftlint")
    if swiftlint:
        run(swiftlint, "lint", "--strict", "--quiet")
    elif os.environ.get("CI") and DARWIN:
        raise SystemExit("SwiftLint is required in CI")
    else:
        print("SwiftLint is not installed; skipped")


def cli() -> None:
    with tempfile.TemporaryDirectory(prefix="narduk-music-cli-") as name:
        out = Path(name) / "build-session.wav"
        result = subprocess.run(
            [
                "swift", "run", "-c", "release", *BUILD_FLAGS, "narduk-music", "render",
                "--scenario", str(SCENARIO), "--out", str(out), "--json",
            ],
            cwd=ROOT, check=True, stdout=subprocess.PIPE, text=True,
        )
        report = json.loads(result.stdout.strip().splitlines()[-1])
        frames = 30 * 48_000
        assert report["seconds"] == 30 and report["sampleRate"] == 48_000, report
        data = out.read_bytes()
        assert data[:4] == b"RIFF" and data[8:12] == b"WAVE", data[:12]
        assert len(data) == 44 + frames * 4, len(data)
        print(f"CLI wrote a 30 s WAV ({len(data)} bytes), fingerprint {report['fingerprint']}")


def consumer() -> None:
    with tempfile.TemporaryDirectory(prefix="narduk-music-swift-") as name:
        temporary = Path(name)
        source = temporary / "narduk-sound"
        source.mkdir()
        shutil.copy(ROOT / "Package.swift", source)
        for tree in ("Sources", "Tests"):
            shutil.copytree(ROOT / tree, source / tree)
        run("git", "init", "--quiet", cwd=source)
        run("git", "add", ".", cwd=source)
        run(
            "git", "-c", "user.name=Package Fixture", "-c", "user.email=fixture@example.invalid",
            "commit", "--quiet", "-m", "Package fixture", cwd=source,
        )
        run("git", "tag", f"v{VERSION}", cwd=source)
        check = temporary / "consumer"
        (check / "Sources/Check").mkdir(parents=True)
        products = ["NardukMusicCore", "NardukMusicRender"]
        if DARWIN:
            # Compile, never run, the README's live-engine example: running it
            # would open the audio device.
            products.append("NardukMusicEngine")
            (check / "Sources/Check/ReadmeExample.swift").write_text(readme_example())
        dependencies = ",\n    ".join(
            f'.product(name: "{product}", package: "narduk-sound")' for product in products
        )
        # Swift 6.2 is the fleet Apple runner's toolchain (Xcode 26.0.1), so the
        # consumer and the root manifest stay at 6.2.
        (check / "Package.swift").write_text(f'''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "Check", platforms: [.macOS(.v15)], dependencies: [
    .package(url: "{source.as_uri()}", exact: "{VERSION}")
], targets: [.executableTarget(name: "Check", dependencies: [
    {dependencies}
])])
''')
        (check / "Sources/Check/main.swift").write_text(CONSUMER)
        out = temporary / "consumer.wav"
        run("swift", "run", *BUILD_FLAGS, "Check", str(SCENARIO), str(out), cwd=check)
        assert out.stat().st_size == 44 + 48_000 * 4, out.stat().st_size
        pins = json.loads((check / "Package.resolved").read_text())["pins"]
        assert any(
            pin["identity"] == "narduk-sound" and pin["state"]["version"] == VERSION
            for pin in pins
        ), pins
        print(f"Verified independent SwiftPM consumer resolved v{VERSION} ({', '.join(products)})")


def main() -> None:
    run("swift", "--version")
    if sys.argv[1:] == ["--consumer-only"]:
        # Resolve the tag and build the products, as an app consumer does.
        consumer()
        return
    if sys.argv[1:]:
        raise SystemExit("usage: swift-quality.py [--consumer-only]")
    lint()
    # One regex over every product of the package (Music, SoundAnalysis, Sonify, SoundVisuals).
    run("swift", "test", *BUILD_FLAGS, "--filter", "NardukMusic|NardukSound|NardukSonify")
    if DARWIN:
        # The allocation checks (every *AllocationTests and *NoAllocTests suite) mean something only in an optimized
        # build. They share libmalloc's one process-wide malloc_logger, so they must not run in parallel: a suite that
        # installs its hook while another is armed makes that one count 0.
        run("swift", "test", "-c", "release", "--no-parallel", "--filter", "AllocationTests|NoAllocTests")
    cli()
    consumer()


if __name__ == "__main__":
    main()
