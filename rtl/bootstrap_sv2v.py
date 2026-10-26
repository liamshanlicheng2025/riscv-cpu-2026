#!/usr/bin/env python3
"""Fetch the pinned Linux x86-64 converter needed only when editing SystemVerilog."""
import hashlib
import io
from pathlib import Path
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
URL = "https://github.com/zachjs/sv2v/releases/download/v0.0.13/sv2v-Linux.zip"
SHA256 = "552799a1d76cd177b9b4cc63a3e77823a3d2a6eb4ec006569288abeff28e1ff8"


def main():
    data = urllib.request.urlopen(URL, timeout=60).read()
    if hashlib.sha256(data).hexdigest() != SHA256:
        raise SystemExit("sv2v archive checksum mismatch")
    destination = (ROOT / "build/tools").resolve()
    destination.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        for entry in archive.infolist():
            target = (destination / entry.filename).resolve()
            if not target.is_relative_to(destination):
                raise SystemExit("invalid archive path")
        archive.extractall(destination)
    binary = destination / "sv2v-Linux/sv2v"
    binary.chmod(0o755)
    print(binary)


if __name__ == "__main__":
    main()
