#!/usr/bin/env python3
"""Fetch single files out of the VocalSet zip (Zenodo 10.5281/zenodo.1193957, CC BY 4.0) with HTTP range requests, so the
2.1 GB archive is never downloaded whole. Files land in a cache outside the repo and are never committed.

    vocalset_fetch.py [--cache DIR] PATTERN...      # substrings of archive paths, e.g. female2/scales/straight/
"""
import argparse, io, os, sys, urllib.request, zipfile

URL = "https://zenodo.org/records/1193957/files/VocalSet.zip?download=1"


class RangeFile(io.RawIOBase):
    def __init__(self):
        resp = urllib.request.urlopen(urllib.request.Request(URL, headers={"Range": "bytes=0-0"}))
        self.size = int(resp.headers["Content-Range"].split("/")[1])
        self.pos = 0

    def seekable(self): return True
    def readable(self): return True
    def tell(self): return self.pos

    def seek(self, offset, whence=0):
        self.pos = offset if whence == 0 else (self.pos + offset if whence == 1 else self.size + offset)
        return self.pos

    def readinto(self, buf):
        n = min(len(buf), self.size - self.pos)
        if n <= 0: return 0
        req = urllib.request.Request(URL, headers={"Range": f"bytes={self.pos}-{self.pos + n - 1}"})
        data = urllib.request.urlopen(req).read()
        buf[: len(data)] = data
        self.pos += len(data)
        return len(data)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cache", default=os.path.expanduser("~/.cache/narduk-sound/vocalset"))
    ap.add_argument("patterns", nargs="+")
    args = ap.parse_args()
    z = zipfile.ZipFile(io.BufferedReader(RangeFile(), buffer_size=1 << 20))
    for info in z.infolist():
        if info.filename.endswith(".wav") and any(p in info.filename for p in args.patterns):
            dest = os.path.join(args.cache, info.filename)
            if os.path.exists(dest) and os.path.getsize(dest) == info.file_size: continue
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, "wb") as out: out.write(z.read(info))
            print("fetched", info.filename, info.file_size)
    return 0


if __name__ == "__main__":
    sys.exit(main())
