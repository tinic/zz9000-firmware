#!/usr/bin/env python3
"""Measure the isolated packet core or combined engine in Vivado; never generate an FPGA image."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


COMMON_INPUTS = (
    "experimental/zz_eth_packet_window.v",
    "test/eth_packet_window/run_ooc.tcl",
    "test/eth_packet_window/run_ooc.py",
)

ENGINE_INPUTS = (
    "experimental/zz_eth_packet_mailbox.v",
    "experimental/zz_eth_packet_axilite.v",
    "experimental/zz_eth_read_arbiter.v",
    "experimental/zz_eth_packet_engine.v",
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--top", choices=("core", "engine"), default="core")
    parser.add_argument("--vivado", default="vivado")
    parser.add_argument("--period-ns", type=float, choices=(10.0, 6.666667), default=10.0)
    parser.add_argument("--output", required=True, type=Path,
                        help="New output directory; existing paths are never overwritten")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent.parent
    # Reject a package or dirty input whose claimed commit cannot be established.
    sha = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
    contents = {}
    inputs = COMMON_INPUTS + (ENGINE_INPUTS if args.top == "engine" else ())
    for rel in inputs:
        data = (root / rel).read_bytes()
        committed = subprocess.check_output(["git", "-C", str(root), "show", sha + ":" + rel])
        if data != committed:
            parser.error("Uncommitted probe input: " + rel)
        contents[rel] = data
    executable = shutil.which(args.vivado)
    if executable is None:
        parser.error("Vivado executable not found: " + args.vivado)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    manifest = {
        "source_commit": sha,
        "input_sha256": {rel: hashlib.sha256(data).hexdigest() for rel, data in contents.items()},
        "top": "zz_eth_packet_engine" if args.top == "engine" else "zz_eth_packet_window",
        "part": "xc7z020clg400-1",
        "period_ns": args.period_ns,
        "boundary_assumptions_ns": {"input_max": 1.0, "input_min": 0.0,
                                    "output_max": 1.0, "output_min": 0.0,
                                    "setup_uncertainty": 0.1, "hold_uncertainty": 0.05},
        "scope": ("Standalone OOC synthesis/place/route; "
                  + ("AXI-Lite/mailbox/core/read-arbiter engine" if args.top == "engine" else "packet core")
                  + "; no live m00, block design or host adapter"),
        "status": "started", "image_ready": False,
        "manual_review_required": ["memory_cells", "constraint coverage", "DRC", "route status"],
    }
    manifest_path = output / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    result_code = 1
    try:
        # Synthesize an immutable snapshot; all Vivado caches stay in this scratch.
        with tempfile.TemporaryDirectory(prefix="work-", dir=output) as work:
            source = Path(work) / "source"
            for rel, data in contents.items():
                target = source / rel
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
            command = [executable, "-mode", "batch", "-nojournal", "-log", str(output / "vivado.log"),
                       "-source", str(source / "test/eth_packet_window/run_ooc.tcl"),
                       "-tclargs", str(output), str(args.period_ns), args.top]
            manifest["command"] = command
            with (output / "console.log").open("w") as log:
                result_code = subprocess.run(command, cwd=work, stdout=log,
                                             stderr=subprocess.STDOUT).returncode
            manifest["vivado_exit_code"] = result_code
            manifest["status"] = "numeric_gate_passed_review_pending" if result_code == 0 else "failed"
    except BaseException as error:
        manifest["status"] = "interrupted_or_failed"
        manifest["error"] = str(error)
        raise
    finally:
        manifest["report_sha256"] = {
            p.name: hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(output.iterdir()) if p.is_file() and p.name != "manifest.json"
        }
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print(str(manifest_path))
    return result_code


if __name__ == "__main__":
    raise SystemExit(main())
