#!/usr/bin/env python3
"""Exercise the exact firmware reset/status functions with MMIO stubs and sanitizers."""
import argparse
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cc", default="clang")
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    source = (here.parent.parent / "ZZ9000_proto.sdk/ZZ9000OS/src/ethernet.c").read_text()
    start = source.index("static int ethernet_packet_fence(void)\n{")
    end = source.index("\nstatic int ethernet_packet_rearm(void)", start)
    test = (here / "packet_reset_test.c").read_text()
    assert test.count("/* EXACT_FENCE_BODY */") == 1
    test = test.replace("/* EXACT_FENCE_BODY */", source[start:end])
    start = source.index("int ethernet_get_backlog() {")
    end = source.index("u16 ethernet_get_rx_stats()", start)
    # Keep both function bodies verbatim; give the legacy empty parameter lists
    # explicit void prototypes so the strict host C99 fixture accepts them.
    getters = source[start:end].replace("() {", "(void) {")
    assert test.count("/* EXACT_STATUS_BODIES */") == 1
    test = test.replace("/* EXACT_STATUS_BODIES */", getters)
    with tempfile.TemporaryDirectory(prefix="arm-live-", dir=here) as build:
        generated = Path(build) / "reset.c"
        generated.write_text(test)
        output = Path(build) / "reset"
        subprocess.run([args.cc, "-std=c99", "-Wall", "-Wextra", "-Werror", "-pedantic",
                        "-O1", "-g", "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                        "-I" + str(here), str(generated), "-o", str(output)], check=True)
        subprocess.run([str(output)], check=True)


if __name__ == "__main__":
    main()
