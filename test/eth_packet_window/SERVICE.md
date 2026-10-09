# ARM packet-service regression and diagnostic limits

Run `python3 test/eth_packet_window/run_service.py` with Clang and Python 3.
The runner compiles the actual `ethernet_packet_service_locked()`,
`ethernet_get_backlog()` and `ethernet_get_rx_status()` bodies, using the real
portable lease/transport helpers. C99, warnings as errors and ASan/UBSan are
enabled. Platform calls and MMIO use a deterministic fixture.

Six groups cover:

* Ring wrap from slot 126 through slot 5, with two bank descriptors plus one
  pending descriptor, an immutable software offer under pressure, publication
  callback order and exactly-once retirement after POP.
* An out-of-order release that must wait for the contiguous completed prefix.
* Rejected and ambiguous POP results: the RELEASED lease stays pinned, service
  faults, no backlog clear/rearm occurs and subsequent calls perform no writes.
* A wrong release cookie that keeps the original lease owned.
* Invalid completed-packet metadata with 120 DDR packets queued: helper rejection
  stops service and RX_STATUS returns ready=0 with backpressure still set.
* Mode, active, fault, hardware-ready and mailbox-running gates, plus the
  low-watermark condition for admitting more GEM buffers.

Temporary negative controls that clear the next slot instead of the released
slot, or omit the service fault latch, must fail. They are not production code.

In packet mode the low RX_STATUS byte describes a readable FPGA bank. It is
forced to zero while the producer is faulted or inactive; it does **not** report
the DDR `frames_backlog` count. A log showing zero ready, backpressure and many
drops is consistent with a full DDR queue behind a stopped producer. Inspect
the actual backlog/read/write/reserve counters, lease count/offered slot,
packet active/fault state and first fault site to distinguish causes.

The invalid-metadata case deliberately supplies a 13-byte completion. It proves
the software behavior for that input, not that GEM delivered that input on the
failing hardware boot. No production recovery policy is changed by this test.

This fixture schedules release events explicitly and has a bounded descriptor
queue; it does not reproduce RTL cycle timing, Zorro host behavior, GEM DMA,
interrupt exclusion or physical cache coherency. Callback ordering assertions
do not prove the cache operations themselves. The allocation stub counts
admission calls without constructing GEM descriptors. The out-of-order case
checks the helper/service contract without asserting such reordering occurred
on the hardware. No boot-reliability or throughput claim follows from a pass.
