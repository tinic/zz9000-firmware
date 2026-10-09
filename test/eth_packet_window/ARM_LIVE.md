# ARM producer candidate for the packet-window integration

This branch connects the lease helper to `ethernet.c` and the proposed live
mailbox. It is a source integration candidate for the separate FPGA/driver
owner, not an image. The combined engine measured at `f1fce5ac` remains the
latest RTL measurement; this change supplies no full-design timing or throughput
result. The original `research/eth-packet-window` branch is unchanged.

## Agreed ARM map

All offsets are bytes from `0x43c00000`. Existing words 0..7 are preserved.

| Offset | Read | Write |
| --- | --- | --- |
| 0x20 | `0x5a505731` (`ZPW1`) capability | Reserved |
| 0x24 | b0 host fence done; b1 ACK/link fence done; b2 completed packet valid; b3 packet mode; b4 running; b6:5 current packet checksum verdict | 1 stop host admission and invalidate snapshot; 2 resume |
| 0x40..0x64 | Mailbox words 0..9 from MAILBOX.md | Same |

The capability must promise the complete map and fence behavior. An older
bitstream without this magic retains legacy RX. After capability selection,
legacy serial ACK handling in ARM cannot free a slot, even during reset/fault.
FPGA packet mode must latch: a halted/stopped engine returns an empty window,
never the raw DDR window while old packet leases remain pinned.

The current integration owner proposes a compatibility host adapter: latch the
full cookie and serial when reading header word zero, and accept a serial ACK
only against that valid snapshot and current head cookie. Snapshot is cleared
on ACK, fence, stopped engine and fabric reset. This needs one synchronous host
read/copy/ACK owner and no bare-1 ACK. It does not distinguish an arbitrary old
serial replay after a newer header with the same 16-bit serial. A general
full-cookie host ABI remains separate work; do not claim equivalent replay
protection. The host/link fences must reject old hardware-pending ACKs and
invalidate the snapshot before rearm.

## Producer and retirement

The GEM ISR retains completed slot length/serial/checksum metadata in packet
mode. The main-loop service publishes payload cache lines, writes the BE header,
and invalidates/synchronizes its first line through the existing PL310 path.
Only then does it stage cookie, metadata and slot, followed by COMMIT. Ordered
MMIO plus DSB and LAST_RESULT validates every write. Pending-mailbox pressure
keeps one immutable software offer; it is not counted twice or re-published.

The service is called on each idle main-loop pass, not the 10 ms Ethernet task
tick. Each pass handles up to four releases and four submissions under GEM IRQ
exclusion. The IRQ pause now restores the previous GIC enable state, so nested
MAC-update/restart calls cannot accidentally reenable the IRQ inside a fence.

A held release must match an owned slot/cookie. ARM marks it released, POPs that
exact cookie and checks LAST_RESULT before retiring the contiguous ring prefix.
Any invalid/ambiguous result or failed POP stops normal service with ownership
intact. The helper state RELEASED is still pinned until retirement or completed
bulk cancellation. Normal retirement clears only the released slot; it does not
clear the next slot as an empty-window convenience. Backlog/watermark accounting
continues to count FPGA-owned packets as completed backlog, not GEM reservations.
Preparing a GEM BD also rejects an already mapped BD, a duplicate reserved slot,
a lease-pinned slot or a slot still inside completed backlog before touching DDR.

Current packet checksum metadata comes from the FPGA head (0x24 bits 6:5), not
`frames_backlog_read`, which can lag after a host ACK until ARM consumes release.
The Amiga interrupt and RX_STATUS ready field both follow completed packet-valid,
not raw DDR backlog. In packet mode, RX_STATUS reports zero while the banks are
empty, stopped or faulted, and one when a bank is ready; reserved/backpressure
diagnostics retain their previous layout. Reporting queued DDR packets as ready
would trigger the driver's stale-window wait (up to 2 ms) inside its interrupt
handler even though the FPGA window is correctly empty. Legacy mode retains its
backlog count and saturation.

## Reset and startup

All ring creation now passes through stopped GEM, packet fence and backlog clear
before rearming descriptors. This also avoids preserving stale reservation counts
across repeated buffer initialization. Restart keeps GEM IRQ excluded from stop
through ring initialization; MAC updates no longer clear the ring before drain.

For packet mode, stop new ARM offers, pin leases for cancellation, complete prior
ordered control accesses, stop host admission and wait for the host/link fence bits before issuing
mailbox FLUSH. Then wait for HALTED+drain-complete and confirm the independent
host/link status bits are still set. The BSP documents
`XEmacPs_Stop` as synchronously stopping DMA; additionally read back RXEN/TXEN
clear and complete ARM stores before asserting the GEM fence. Hardware validation
must verify this platform contract; a CPU DSB by itself is not a DMA drain.
Only then may the helper clear leases and the firmware rebuild GEM/ring state.
After rebuilding, verify REARM and resume the host before starting GEM.

The bounded wait (10,000 status polls) is only a failure escape. On failure, keep
the host stopped, all leases pinned, GEM stopped and link readiness false. No
timeout is treated as cancellation completion. Retry requires an explicit reset;
there is no unbounded busy loop or background reuse of the old slots. Cookie
exhaustion initiates the same fence; ordinary logical resets preserve allocation.

The template CSR integration has no separate AXI-Lite adapter: the sole ordered
ARM writer must finish its old requests before FLUSH, and the template must keep
exactly-once write strobes and write-result ordering. The fence word's link bit
covers FPGA ACK queues; it does not replace the ARM upstream ordering guarantee.

## Validation and remaining checks

`run_transport.py` runs the real C transport/helper with a small mailbox model
under ASan/UBSan, warnings as errors. Four groups cover pressure, explicit field
encoding, exactly-once accepted COMMIT, rejected shadow/COMMIT retry, ambiguous
write results, wrong release identities, bad reserved release bits, failed POP
and late releases during reset. It does not execute FPGA RTL, the platform IRQ
controller or GEM DMA.

`run_live.py` also extracts the exact firmware reset-fence function and runs
four MMIO-stub checks: successful ordered drain, host timeout, core timeout and
GEM still-enabled rejection. All failures keep leases pinned. Two additional groups
exercise the actual RX status/get-backlog bodies across empty/ready/drained/stopped/
faulted banks, legacy backlog saturation and unchanged pressure diagnostics. The
empty-bank/nonempty-DDR assertion fails before the RX_STATUS fix. These tests do not
prove the hardware fence signals or XEmacPs DMA-stop implementation.

The actual `ethernet.c` cross-compiles with Arm GNU 15.3.1 Cortex-A9 flags. `-Wall -Werror` passes. With
`-Wall -Wextra`, the same three warnings occur in the unchanged baseline and
candidate (two unused callback parameters and a legacy signedness comparison).
The stricter all-warning gate therefore remains nonzero for both; no warnings
were suppressed or unrelated code changed to hide that result.

The owning integration chat must review the exact commit, combine it with its
FPGA/driver changes, compile/link the full firmware, verify reset/host fences and
status metadata, and measure full-design resources/routed timing before an image
claim. Hardware work remains under that chat's existing user authorization.
