#!/usr/bin/env python3
"""Exercise actual ARM packet service/status bodies with a bounded mailbox model."""
import argparse
from pathlib import Path
import subprocess
import tempfile


def function(source, signature):
    start = source.index(signature)
    return source[start:source.index("\n}", start) + 2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cc", default="clang")
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    source = (here.parent.parent / "ZZ9000_proto.sdk/ZZ9000OS/src/ethernet.c").read_text()
    bodies = "\n\n".join(function(source, signature) for signature in [
        "static void ethernet_packet_service_locked(void)\n{",
        "int ethernet_get_backlog() {",
        "u16 ethernet_get_rx_status() {",
    ]).replace("() {", "(void) {")
    test = (here / "packet_service_test.c").read_text()
    assert test.count("/* EXACT_SERVICE_BODIES */") == 1
    test = test.replace("/* EXACT_SERVICE_BODIES */", bodies)
    with tempfile.TemporaryDirectory(prefix="arm-service-", dir=here) as build:
        generated = Path(build) / "service.c"
        generated.write_text(test)
        output = Path(build) / "service"
        subprocess.run([args.cc, "-std=c99", "-Wall", "-Wextra", "-Werror", "-pedantic",
                        "-O1", "-g", "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                        "-I" + str(here), str(generated), "-o", str(output)], check=True)
        subprocess.run([str(output)], check=True)


if __name__ == "__main__":
    main()
