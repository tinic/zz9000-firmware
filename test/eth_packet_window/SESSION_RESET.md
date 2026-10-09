# Packet-session reset regression

The startup path calls `ethernet_init()` and then `handle_amiga_reset()` before
the Ethernet task reaches READY. `ethernet_reset_for_amiga()` consequently takes
its pause/clear/resume path before the first packet session. At `fcc85f38`, the
clear guard incorrectly faults because no packet fence has yet completed.

`e7d0f55ad0b8afdb348c6974051145a9034bd7ba` permits this pre-session clear using
`packet_session_started`, set only after successful rearm and never cleared by a
logical fence or failure. This assumes cold ARM startup also starts from the
agreed common fabric-reset state; restarting ARM alone over a surviving packet
engine is not covered. A rejected or ambiguous first REARM result cannot enable
ARM descriptor submissions. Once any session has started, zero leases and an
inactive producer do not prove that a clear is safe: a completed fence is still
required.

Run with Python 3 and Clang/ASan/UBSan:

```sh
python3 test/eth_packet_window/run_session.py
```

The runner extracts the actual fence, rearm, clear and Amiga-reset caller bodies
from `ethernet.c` and `ethernet_mcast.c`. It supplies a minimal platform/MMIO
fixture and the real portable lease/transport helpers, compiling with C99,
`-Wall -Wextra -Werror -pedantic` and sanitizers. Its six groups cover:

* Cold not-READY reset before the first session, including cleared counters and
  slots and the pause/resume call pairing.
* First REARM failure: missing fence, existing fault, explicit rejection and
  ambiguous result; none enables submissions or host resume.
* Later not-READY reset with an active session and with an inactive, empty
  session; both reject unfenced clear.
* Host timeout, rejected FLUSH, core timeout and enabled GEM readback; each keeps
  the session marker and lease pinned through the subsequent reset caller.
* Completed fence followed by clear and rearm; lease reclamation preserves
  cookie allocation and session history.
* Legacy clear behavior and the READY caller's delegation to DMA restart.

The cold-reset assertion fails against `fcc85f38` and all six groups pass
against `e7d0f55a`. Temporary negative controls replacing the monotonic guard
with `packet_active || packet_leases.count`, and clearing the marker during a
successful fence, must fail their respective assertions. Mutations are not
production source.

The READY restart routine, GEM/GIC implementation, cache publication, physical
MMIO ordering, fabric reset and hardware fence semantics are not simulated by
this fixture. In particular, a later not-READY reset is safely rejected here;
the test does not claim that this caller itself performs recovery. These checks
do not establish the cause of the separately reported hardware RX stall or a
throughput improvement.
