#!/usr/bin/env python3
"""Build isolated parameter variants; run official IPC and directed regressions."""
import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VARIANTS = {
    "single": ["ISSUE_WIDTH=1", "COMMIT_WIDTH=1", "INTEGER_PORTS=1"],
    "rob8": ["ROB_DEPTH=8"],
    "direct": ["DCACHE_WAYS=1"],
    "dcache4k": ["DCACHE_BYTES=4096"],
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jobs", type=int, default=8)
    parser.add_argument("--variant", choices=VARIANTS, action="append")
    args = parser.parse_args()
    results = []
    for name in args.variant or VARIANTS:
        directory = ROOT / "build/sweep" / name
        directory.mkdir(parents=True, exist_ok=True)
        output = directory / "cpu.v"
        params = [arg for value in VARIANTS[name] for arg in ("--param", value)]
        subprocess.run([sys.executable, "rtl/export_ooo.py", "--output", str(output), *params], cwd=ROOT, check=True)
        filelist = directory / "filelist.f"
        filelist.write_text("cpu.v\n")
        command = ["make", "build", f"FILELIST={filelist}", f"BUILD={directory}", f"JOBS={args.jobs}"]
        with (directory / "build.log").open("w") as log:
            subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
        sim = directory / "sim"
        for kind in ("correctness", "perf"):
            run = subprocess.run([sys.executable, "scripts/testcase.py", "--sim", str(sim), "--kind", kind,
                                  "--max-cycles", "100000000"], cwd=ROOT, text=True, capture_output=True)
            (directory / (kind + ".log")).write_text(run.stdout + run.stderr)
            run.check_returncode()
            if kind == "perf":
                ipc = float(re.search(r"GEOMEAN\s+([0-9.]+)", run.stdout)[1])
        with (directory / "directed.log").open("w") as log:
            subprocess.run([sys.executable, "rtl/regress.py", "--sim", str(sim), "--latency", "10"],
                           cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
        result = dict(name=name, parameters=VARIANTS[name], ipc=ipc,
                      rtl_sha256=hashlib.sha256(output.read_bytes()).hexdigest())
        results.append(result)
        (ROOT / "build/sweep/results.json").write_text(json.dumps(results, indent=2) + "\n")
        print(result, flush=True)


if __name__ == "__main__":
    main()
