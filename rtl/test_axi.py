#!/usr/bin/env python3
"""Exercise the actual adapter with random, independent AR/AW/W/R/B stalls.

Harness derived from Galuisss/ACM-CPU at b76000b65bfa7ef9aca57ef27478ce33fa488791.
"""
import subprocess
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from toolchain import DEFAULT_APPIMAGE, enter_appimage, packaged_tool, executable


def main():
    enter_appimage(DEFAULT_APPIMAGE)
    out = ROOT / "build/axi"
    out.mkdir(parents=True, exist_ok=True)
    # AppImage mount paths change between invocations; generated dependency
    # files must not retain include paths from a previous mount.
    objects = out / "obj"
    if objects.is_symlink():
        objects.unlink()
    elif objects.exists():
        shutil.rmtree(objects)
    sources = [ROOT / "rtl/ooo/student_top.sv", ROOT / "rtl/tests/axi/cpu_top.sv",
               ROOT / "rtl/tests/axi/backpressure.cpp"]
    command = [packaged_tool("verilator") or executable("verilator"), "--cc", "--exe", "--build",
               "--assert", "-Wall", "-Wno-fatal", "--top-module", "student_top", "-j", "4",
               "--Mdir", str(out / "obj"), "-o", str(out / "test"), "-CFLAGS", "-std=c++17", *map(str, sources)]
    with (out / "build.log").open("w") as log:
        subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
    run = subprocess.run([str(out / "test")], text=True, capture_output=True, timeout=60)
    (out / "test.log").write_text(run.stdout + run.stderr)
    print(run.stdout + run.stderr, end="")
    if run.returncode or run.stdout.count("PASS AXI") != 12:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
