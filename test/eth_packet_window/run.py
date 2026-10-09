#!/usr/bin/env python3
"""Compile and run the isolated packet-window experiment; leave no build files."""
import argparse
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iverilog", default="iverilog")
    parser.add_argument("--vvp", default="vvp")
    parser.add_argument("--ivl-dir", type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--shared-port", action="store_true",
                        help="Place packet fetches behind the foreground-priority read arbiter")
    mode.add_argument("--mailbox", action="store_true",
                      help="Exercise the registered CSR descriptor/release backend with the real core")
    parser.add_argument("--id-width", type=int, choices=(1, 2), default=2,
                        help="AXI transaction ID width (1 matches live m00; 2 detects truncation)")
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    root = here.parent.parent
    with tempfile.TemporaryDirectory(prefix=".sim-", dir=here) as directory:
        output = str(Path(directory) / "packet_window.vvp")
        compile_args = [args.iverilog]
        run_args = [args.vvp]
        if args.ivl_dir:
            compile_args += ["-B", str(args.ivl_dir.resolve())]
            run_args += ["-M", str(args.ivl_dir.resolve())]
        if args.shared_port:
            compile_args += ["-DSHARED_READ_PORT"]
        top = "mailbox_tb" if args.mailbox else "packet_window_tb"
        if not args.mailbox:
            compile_args += ["-P", "packet_window_tb.TEST_ID_WIDTH=" + str(args.id_width)]
        compile_args += [
            "-g2012", "-Wall", "-s", top, "-o", output,
            str(root / "experimental/zz_eth_packet_window.v"),
            str(root / "experimental/zz_eth_read_arbiter.v"),
            str(root / "experimental/zz_eth_packet_mailbox.v"),
            str(here / (top + ".v")),
        ]
        subprocess.run(compile_args, check=True)
        subprocess.run(run_args + [output], check=True)


if __name__ == "__main__":
    main()
