# Registered ARM descriptor and release backend

`experimental/zz_eth_packet_mailbox.v` is an offline CSR backend connected to the
real packet core in `mailbox_tb.v`. It is not yet wired into MNTZorro's AXI-Lite
slave or assigned live addresses. The indices below are local module word
selectors, **not firmware MMIO addresses or a negotiated host ABI**.

The intended clock is FCLK0 at 100 MHz. `zz9000_project.tcl:1405` at `4ed675f6`
connects MNTZorro `S_AXI_ACLK`, `m00_axi_aclk` and `m01_axi_aclk` to that clock;
zz9k-fpga independently confirmed the connection. No CDC is needed between this
control backend and the packet core. A future different-domain endpoint must
use an atomic record bridge with its own reset acknowledgement. The asynchronous
Zorro pins still require their existing synchronizers and a separate host adapter.

## Bus adapter and writer contract

`csr_write` is exactly one pulse per already accepted write transaction. The
adapter must capture address, data and all four byte strobes together after both
AXI-Lite AW and W have arrived; it must neither assume simultaneous AW/W nor
replay the pulse while BREADY is low. Reads have no side effects. Every write
completes without waiting for bank capacity, so ARM can always read/pop releases.

`csr_error` describes logical rejection on that write's clock edge. `LAST_RESULT`
holds the same outcome and selector for software. The adapter may return normal
AXI completion for expected BUSY rejection and let software inspect this result;
do not turn ordinary queue pressure into an ARM data-abort exception or an
unbounded bus stall. Actual AXI channel handling is a required next step, not
implemented by this backend.

There must be **one writer context** for staging, COMMIT, result reads, release
processing and reset. The live driver can publish from IRQ and main-loop paths;
serialize the whole sequence against GEM IRQs using the exclusion contract in
[ARM_CONTRACT.md](ARM_CONTRACT.md). Individual atomic MMIO words cannot prevent
two writers from interleaving descriptor fields. Finish payload/header/cache
publication before staging, and enforce the platform's MMIO barriers/order.

## Local word selectors

All writes require all four byte strobes. A partial, unknown or invalid write is
rejected without changing the targeted state; its failure is recorded in
`LAST_RESULT`. No side effect occurs merely by reading a word.

| Word | Meaning |
| --- | --- |
| 0 | Read STATUS: bit 0 RUNNING, 1 DRAINING, 2 HALTED, 3 drain complete, 4 committed descriptor pending, 5 release snapshot held; bits 10:8 shadow-word dirty mask |
| 1 | Read/write shadow cookie, full 32 bits; zero is invalid for COMMIT |
| 2 | Read/write shadow metadata: serial in 31:16, length in 11:0, reserved 15:12 must be zero |
| 3 | Read/write shadow slot/verdict: slot in 6:0, checksum verdict in 8:7; reserved 31:9 must be zero |
| 4 | Write COMMIT using the staged cookie as data |
| 5 | Read held release cookie, meaningful only with held status while RUNNING |
| 6 | Read held release metadata: slot 6:0, error bit 7 |
| 7 | Write POP using the exact held release cookie |
| 8 | Write CONTROL: 1 = FLUSH, 2 = REARM; other values rejected |
| 9 | Read LAST_RESULT: bit 8 valid, bits 7:4 last write selector, bit 0 rejected; reset clears valid |

COMMIT requires RUNNING, all three newly written shadow words, no pending committed
descriptor, zero reserved bits, nonzero cookie and an exact cookie match in the
COMMIT write. A success copies all fields into separate output registers and
clears the dirty mask. A repeated COMMIT without restaging is rejected. Shadow
writes for the next descriptor may continue while the committed descriptor is
stalled; they never change its registered fields. A BUSY rejection preserves
the new shadow values for a later retry. The core's bank-ready handshake controls
admission; the backend does not guess the number of free banks.

After checking successful COMMIT's LAST_RESULT under writer exclusion, ARM may
call `zz_rx_lease_accept()`: the complete descriptor is now durably owned by the
backend, even before the core accepts it. Keep the DDR slot pinned. Readback
ordering must ensure the result belongs to that write, and process acceptance
before any returned release. A reset that makes completion ambiguous requires
coordinated cancellation; never infer that a potentially accepted slot is free.
The backend does not detect duplicate producer cookies/slots across transactions;
the ARM lease helper and session discipline retain that responsibility.

## Release and backpressure

One release snapshot is held until a matching POP. Repeated reads, wrong cookies,
duplicate POPs and partial writes do not remove it. While held, the backend
deasserts the core's release-ready signal. The core can hold one further release
and backpressures host ACK when its own record cannot advance. Descriptor COMMIT
pressure never prevents ARM from popping a release.

ARM reads the held flag and both stable words, validates slot/cookie with the
lease helper, and calls `zz_rx_lease_release()`. Then it POPs that cookie, checks
the write result, and retires the contiguous released prefix under the same GEM
exclusion. A failed POP must stop recovery/retirement until ownership is resolved.
An error release follows the same ownership path but delivers no packet data.
Normal release processing and reset cancellation must not retire the same slot twice.

## Reset and explicit rearm

Fabric reset resets the backend, packet core and AXI path together. The backend
starts HALTED with drain-complete clear. Startup therefore uses FLUSH, waits for
HALTED with drain-complete set, then issues REARM after the other session fences.

FLUSH or a rising `flush_request` stops descriptor admission and release transfer
immediately and sends **one pulse** to the core. It rejects a coincident ordinary
CSR write. The core retains stalled AR and accepted response ownership and drains
through RLAST. The backend remains DRAINING, keeping its queued descriptor and
held-release state until the actual `core_flush_done` pulse. Only then does it
discard those local old-session records and enter HALTED. Shadow dirty bits are
invalidated, so pre-reset staging cannot commit after rearm.

A held external request does not repeatedly pulse core flush. REARM is rejected
while that request remains high, before drain completion, or outside HALTED.
Repeated FLUSH writes during DRAINING are idempotent. A new FLUSH from HALTED
requires a fresh drain; no elapsed-time shortcut is used.

HALTED/drain-complete establishes **core plus this backend** quiescence only.
The adapter/software must separately fence upstream MMIO queues and write/read
responses, GEM DMA/IRQ activity and old host operations before clearing/rebuilding
the ring or reusing cookies. Old posted writes must not arrive after REARM. The
four ARM-helper fence bits must never be set just from this one status word.
`ethernet_reset_for_amiga`/DMA restart must follow flush → drain → HALTED before
ring reinitialization; the existing live restart IRQ fix remains a separate owner.

## Validation and remaining work

Run `python3 test/eth_packet_window/run.py --mailbox`. Four groups exercise atomic
staging, zero/reserved fields and partial-write rejection, exactly-once commit,
stable queued descriptors while shadow fields change, BUSY retry, release snapshots
and exact POP, two-bank/release backpressure, error releases, flush winning a
concurrent write, a held reset request, stalled AXI AR plus 25 us delayed data,
queued descriptors/releases across drain, explicit rearm and common fabric reset.
The accepted/committed difference at completion includes one queued descriptor
cancelled by the coordinated flush; it is not a lost normal transaction.

This is an RTL test of the real core and backend, not an ARM/C-helper cosimulation,
AXI-Lite channel test, host-driver test, CDC test or hardware run. The existing
core and shared-port suites also remain required. No mailbox resource/timing
measurement has been made: the earlier two-RAMB18/293-LUT result measures the core
alone and must not be applied to the combined design. The next steps are a real
AXI-Lite adapter, assigned compatible register/capability protocol, C integration,
combined timing with the actual clock/boundary, and the shared-m00/Zorro adapter.
