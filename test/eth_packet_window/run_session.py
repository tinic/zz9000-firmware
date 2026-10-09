#!/usr/bin/env python3
"""Test actual cold-start/session-reset bodies; MMIO and platform calls are stubs."""
import argparse
from pathlib import Path
import subprocess
import tempfile


def function(source, signature):
    start = source.index(signature)
    # These firmware functions have their closing brace alone at column zero.
    end = source.index("\n}", start) + 2
    return source[start:end]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cc", default="clang")
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    firmware = here.parent.parent / "ZZ9000_proto.sdk/ZZ9000OS/src"
    source = (firmware / "ethernet.c").read_text()
    caller = (firmware / "ethernet_mcast.c").read_text()
    bodies = "\n\n".join([
        function(source, "static int ethernet_packet_fence(void)\n{"),
        function(source, "static int ethernet_packet_rearm(void)\n{"),
        function(source, "void ethernet_clear_host_state(void) {"),
        function(caller, "void ethernet_reset_for_amiga(void)\n{"),
    ])
    test = (here / "packet_session_test.c").read_text()
    assert test.count("/* EXACT_SESSION_BODIES */") == 1
    test = test.replace("/* EXACT_SESSION_BODIES */", bodies)
    with tempfile.TemporaryDirectory(prefix="arm-session-", dir=here) as build:
        generated = Path(build) / "session.c"
        generated.write_text(test)
        output = Path(build) / "session"
        subprocess.run([args.cc, "-std=c99", "-Wall", "-Wextra", "-Werror", "-pedantic",
                        "-O1", "-g", "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                        "-I" + str(here), str(generated), "-o", str(output)], check=True)
        subprocess.run([str(output)], check=True)


if __name__ == "__main__":
    main()
