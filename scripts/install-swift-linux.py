"""Select verified fleet Swift, or install the signed release in job-local storage."""

import gzip
import os
import platform
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
from pathlib import Path

# One signed swift.org archive per supported Ubuntu release. A distro archive
# only runs on the release it was built for: the 24.04 build's lld links
# libxml2.so.2, which Ubuntu 26.04 no longer ships (it has libxml2.so.16), and
# swift.org publishes no 26.04 build of 6.3.3. 6.4.0 is the first release with
# an official ubuntu26.04 archive.
TOOLCHAINS = {
    "24.04": ("6.3.3", "ubuntu24.04"),
    "26.04": ("6.4.0", "ubuntu26.04"),
}


def toolchain(os_release: dict[str, str]) -> tuple[str, str, str]:
    """Return (version, archive name, URL) for this Ubuntu release."""
    version_id = os_release.get("VERSION_ID", "")
    if os_release.get("ID") != "ubuntu" or version_id not in TOOLCHAINS:
        supported = ", ".join(f"Ubuntu {release}" for release in TOOLCHAINS)
        found = f"{os_release.get('ID', 'unknown')} {version_id}".strip()
        raise RuntimeError(
            f"No pinned signed Swift archive for {found}; supported: {supported}"
        )
    version, platform_name = TOOLCHAINS[version_id]
    archive = f"swift-{version}-RELEASE-{platform_name}"
    directory = platform_name.replace(".", "")
    url = (
        f"https://download.swift.org/swift-{version}-release/"
        f"{directory}/swift-{version}-RELEASE/{archive}.tar.gz"
    )
    return version, archive, url


def run(*args: str, env: dict[str, str] | None = None) -> str:
    try:
        return subprocess.check_output(
            args, text=True, env=env, stderr=subprocess.STDOUT
        )
    except subprocess.CalledProcessError as error:
        print(error.output, flush=True)
        raise


def verify(binary: Path, version: str) -> bool:
    if not binary.is_file():
        return False
    try:
        if f"Swift version {version.removesuffix('.0')}" not in run(str(binary), "--version"):
            return False
        with tempfile.TemporaryDirectory(prefix="narduk-swift-smoke-") as directory:
            root = Path(directory)
            (root / "check.swift").write_text('print("swift-ready")\n')
            run(
                str(binary),
                "-use-ld=lld",
                str(root / "check.swift"),
                "-o",
                str(root / "check"),
            )
            return run(str(root / "check")).strip() == "swift-ready"
    except subprocess.CalledProcessError:
        return False


def download(url: str, target: Path) -> None:
    request = urllib.request.Request(url, headers={"Accept-Encoding": "identity"})
    with (
        urllib.request.urlopen(request, timeout=120) as response,
        target.open("wb") as output,
    ):
        if response.headers.get("Content-Encoding") == "gzip":
            with gzip.GzipFile(fileobj=response) as decoded:
                shutil.copyfileobj(decoded, output)
        else:
            shutil.copyfileobj(response, output)


def main() -> None:
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        raise RuntimeError("This installer requires an x86_64 Linux CI runner")
    version, archive_name, url = toolchain(platform.freedesktop_os_release())
    fleet = Path(f"/opt/narduk/swift/{version}/usr/bin")
    if verify(fleet / "swiftc", version):
        binary_directory = fleet
        print(f"Verified fleet Swift {version}")
    else:
        root = Path(os.environ["RUNNER_TEMP"]) / "narduk-logging-swift"
        root.mkdir(exist_ok=False)
        archive = root / "swift.tar.gz"
        signature = root / "swift.tar.gz.sig"
        keys = root / "keys.asc"
        print(f"Installing signed Swift {version} ({archive_name}) in job-local storage", flush=True)
        download(url, archive)
        download(url + ".sig", signature)
        download("https://www.swift.org/keys/all-keys.asc", keys)
        # Runner work paths can exceed GPG's Unix socket length limit. Keep
        # this isolated public keyring short even when RUNNER_TEMP is long.
        with tempfile.TemporaryDirectory(
            prefix="narduk-swift-keys-", dir="/tmp"
        ) as keyring:
            env = dict(os.environ, GNUPGHOME=keyring)
            run("gpg", "--batch", "--import", str(keys), env=env)
            run("gpg", "--batch", "--verify", str(signature), str(archive), env=env)
        with tarfile.open(archive) as package:
            package.extractall(root, filter="data")
        archive.unlink()
        binary_directory = root / archive_name / "usr/bin"
        if not verify(binary_directory / "swiftc", version):
            raise RuntimeError(
                "The signed Swift toolchain failed its compile/link smoke check"
            )
        print(f"Verified signed Swift {version}")
    with Path(os.environ["GITHUB_PATH"]).open("a") as output:
        output.write(str(binary_directory) + "\n")


if __name__ == "__main__":
    main()
