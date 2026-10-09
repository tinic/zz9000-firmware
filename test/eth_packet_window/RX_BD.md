# RX descriptor ownership under backpressure

`910970b71d84fbf75544d2e01975f1cc09dd3476` clears a completed descriptor's NEW
bit before deciding whether refill is admitted. NEW=0 grants GEM ownership of
the address still in that descriptor, even after the software ring frees it.
At the 120-packet high watermark, refill stops but those descriptors remain
writable by DMA at old DDR slot addresses. This breaks packet lifetime and can
desynchronize the GEM and software ring. Preparation also clears NEW before
updating the address, and before a potentially failing `BdRingToHw()` call.

The bundled emacps_v3_8 `XEmacPs_BdRingFromHwRx()` only tests `HwCnt==0` before
walking up to `BdLimit`; it does not otherwise stop at `HwCnt`. Once free BDs
correctly retain NEW=1, passing 64 unconditionally can count old software-owned
completions and underflow the hardware count. The ownership fix and scan bound
belong together.

Owner candidate `9a790af25b53d798d27e6f587f896b8c46463855` changes `ethernet.c`
only. RX templates start with NEW=1. Completion and preparation retain it;
addresses, reservations and successful software ring submission precede a DSB
and clearing NEW. Failed submission never grants DMA ownership. Completion
scanning uses the hardware work-group count. No BSP file is changed.

## Reproduction

```sh
python3 test/eth_packet_window/run_rx_bd.py
python3 test/eth_packet_window/run_rx_bd.py --legacy
```

An optional case name runs one scenario: `pressure`, `scan`, `publish`,
`rollback`, `cycle` or `burst`. Python 3 and Clang with ASan/UBSan are required.

The runner extracts the actual firmware prepare/unprepare/allocate/receive
bodies and actual bundled BSP Alloc/UnAlloc/ToHw/FromHwRx/Free functions, ring
structure, traversal macros and descriptor bit macros. A fixture supplies MMIO,
cache and DMA events. It observes every descriptor address write: software must
have assigned the new slot and recorded ring ownership before granting DMA.

The six cases cover held ownership at the watermark; stale NEW/EOF in software
descriptors beyond HwCnt; address/reservation/accounting before handoff;
ToHw rejection with no DMA grant; a 120-packet stop at BD56 followed by host
drain/refill; and batches of 64 then 56 completions without stale-BD overcount.
The original five cases fail their intended runtime assertions at `910970b`.
All six pass at `9a790af`, in both packet and legacy modes (12 runs).

Host adaptations are explicit: descriptor indexing uses pointer-sized host
addresses; the target's 32-bit descriptor address macros are selected; the
empty allocation prototype becomes `(void)`. The local `rx_bytes` type becomes
unsigned after checking the actual length mask is 13 bits (0..8191), preserving
values and control flow while accepting the strict host warning gate. This
does not repair or hide the separately recorded production signedness warning.
No compiler warnings are disabled; the fixture uses C99, `-Wall -Wextra
-Werror -pedantic`, ASan and UBSan.

This test does not execute cold ring creation/start, physical cache barriers,
GEM timing or interrupts. Its initial ring is explicitly software-owned;
the actual initial RX template and bulk handoff require source/build review.
The drain step models host retirement by advancing completed backlog state;
packet mailbox/cookie semantics have separate tests. Sequential DMA events do
not reproduce every interleaving or prove that a hardware boot is fixed.

The hardware owner separately reported a fault snapshot with GEM at BD16,
software HwHead at BD56/HwCnt24 and software-free descriptors still DMA-owned.
That supports the same mechanism, but the clean candidate needs its own
exact-image repeatability and traffic measurements. Prior timing/resource
results remain tied to the unchanged FPGA image; this is an ARM-side fix.
