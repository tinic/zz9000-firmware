#!/usr/bin/env python3
"""Compile the isolated ARM ownership helper with host sanitizers; no SDK needed."""
import argparse
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cc", default="clang")
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    with tempfile.TemporaryDirectory(prefix="arm-lease-", dir=here) as build:
        output = str(Path(build) / "rx_lease_test")
        subprocess.run([args.cc, "-std=c99", "-Wall", "-Wextra", "-Werror", "-pedantic",
                        "-O1", "-g", "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                        str(here / "rx_lease_test.c"), "-o", output], check=True)
        subprocess.run([output], check=True)


if __name__ == "__main__":
    main()
