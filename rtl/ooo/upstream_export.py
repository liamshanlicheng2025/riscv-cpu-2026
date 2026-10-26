#!/usr/bin/env python3
"""Export synthesizable Verilog-2005 from the complete SystemVerilog CPU."""
import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def convert(sources, sv2v):
    """Convert an explicit, already snapshotted source list to plain Verilog."""
    command = [str(sv2v), "-DSYNTHESIS", "-E", "Always", *map(str, sources)]
    converted = subprocess.check_output(command, cwd=ROOT, text=True)
    # sv2v drops metacomments and resolves preprocessor defaults. Preserve
    # this read-helper implementation hint in the portable source: both
    # SIM_FAST values implement the same function, checked by SAT tests.
    def preserve_fast_eval(match):
        module = match[1]
        module = re.sub(r"(\bmodule\s+\w+\b[^;]*;)",
                        r"\1\n/* verilator inline_module */\n/* verilator tracing_off */", module, count=1)
        return re.sub(r"(parameter\s+(?:integer\s+)?SIM_FAST\s*=)\s*([^;]+);",
                      r"\1\n`ifdef VERILATOR\n1\n`else\n\2\n`endif\n;", module, count=1)
    converted = re.sub(r"\(\*\s*verilator_fast_eval\s*=\s*1\s*\*\)\s*(module\s+\w+\b.*?\bendmodule\b)",
                       preserve_fast_eval, converted, flags=re.S)
    # Preserve process kinds through sv2v, then use portable Verilog processes.
    # Explicit entire-array sensitivity lists are rejected by strict readers.
    converted = re.sub(r"\balways_comb\b", "always @*", converted)
    converted = re.sub(r"\balways_ff\b", "always", converted)
    converted = re.sub(r"\balways_latch\b", "always @*", converted)
    return converted, command


def export(output, sv2v, source_root=ROOT):
    sources = [source_root / "rtl/cpu_pkg.sv"] + sorted(
        path for path in (source_root / "rtl").glob("*.sv") if path.name != "cpu_pkg.sv")
    # The course owns this macro. Converting its simulation model with
    # SYNTHESIS defined would emit an empty duplicate module and silently
    # remove SRAM behavior from an exported-core differential simulation.
    simulation_libraries = [p for p in sources if p.name == "sram_fakeram.sv"]
    sources = [p for p in sources if p not in simulation_libraries]
    converted, command = convert(sources, sv2v)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(converted)
    metadata = {
        "rtl_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "source_root": str(source_root),
        "commit_scope": "workspace Git context; exact inputs are identified by sources_sha256",
        "sv2v": subprocess.check_output([str(sv2v), "--version"], text=True).strip(),
        "sources_sha256": {str(p.relative_to(source_root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
        "output_sha256": hashlib.sha256(output.read_bytes()).hexdigest(), "command": command,
        "simulation_libraries_sha256": {str(p.relative_to(source_root)): hashlib.sha256(p.read_bytes()).hexdigest()
                                         for p in simulation_libraries},
    }
    output.with_suffix(".metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"Exported Verilog to {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/synth/cpu.v")
    parser.add_argument("--sv2v", type=Path, default=ROOT / "build/tools/sv2v-Linux/sv2v")
    parser.add_argument("--source-root", type=Path, default=ROOT)
    args = parser.parse_args()
    export(args.output.resolve(), args.sv2v.resolve(), args.source_root.resolve())
