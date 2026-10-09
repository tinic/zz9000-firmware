# Packet-sized FPGA receive-window prototype

Status: **offline experiment, not integrated into any firmware build**. No image
was built or flashed for this prototype. A Vivado 2018.3 isolated 100 MHz probe
measured two RAMB18s, 293 LUTs and 254 FFs; setup and internal hold passed, but the
overall hold gate failed on input-boundary timing. See [the measured results and
limits](OOC.md). Full-design routed timing, clock-domain crossings and hardware
performance remain unverified. The nofast control/read-ahead experiment is separate.

The initial packet core at `e81420cc` received an independent source review from
zz9k-fpga: no core correctness blocker found; tests were not independently rerun.
Two RAMB18s is the reviewer's area estimate, not measured synthesis. The isolated
foreground/prefetch arbitration model at `7b852b90` also received a source review
with no correctness blocker identified. That review requested AXI attribute/ID
preservation and a simultaneous-arrival priority test. This follow-up implements
both at `efc04df2`, with no blocker in the subsequent source review. It still does not modify the
live m00 engine or its Zorro-pin testbench.

## What this experiment establishes

The existing RX path has 128 x 2 KB DDR slots and 64 GEM receive descriptors.
The MAC writes packet payload directly into a reserved slot. ARM publishes its
length/serial after cache maintenance; the current Zorro window maps one slot.
After copying it, the Amiga writes its serial to the receive register, and ARM
advances the window. Baseline Zorro reads issue one AXI read per longword.

This prototype implements two 2 KB FPGA packet banks. A producer describes a
completed DDR slot; the module fetches it in bursts of at most 16 longwords.
Only a complete, checked fill becomes readable. One bank can fill while the
other is held by the host. Reads use synchronous local memory and do not consume
bytes; ACK releases a whole packet. The bulk DDR backlog stays in DDR.

This arrangement separates two benefits that need separate measurement:

* DDR ring capacity absorbs bursts; simply enlarging it does not shorten reads.
* FPGA packet banks can hide internal DDR latency and overlap the next fill.

The separate read-ahead experiment reported approximately 569 ns per longword
from DDR and 452 ns from its 64-byte cache on the A3000/060. Those are earlier
measurements, not results from this prototype or a matched nofast comparison.
They imply about a 21% reduction in read latency (26% increase in raw read rate)
for that path, not an equivalent TCP gain. The Zorro front end and software
copies remain. Changing that front end is outside this prototype.

## Descriptor, publication and ownership contract

All module signals use one clock. Cross-domain transport is an integration task.
The [registered mailbox backend](MAILBOX.md) now exercises atomic ARM descriptor
commit and matching release snapshots with this core at the shared 100 MHz clock.
The [AXI-Lite adapter](AXILITE.md) adds independent AW/W capture, held responses
and local quiesce/drain tests. Neither component has a live address allocation
or host adapter. The existing eight-word ARM aperture is fully occupied; this
ten-word mailbox needs a widened decode or separate slave.
The separate [ARM integration contract](ARM_CONTRACT.md) now provides a portable
ownership helper and host tests for publication order, matching releases,
contiguous ring retirement and coordinated reset fences. It is not linked into
firmware or connected to this RTL. Source review of `df70ad8` found no blocker;
its tests were not independently rerun by that reviewer.

1. The producer reserves a DDR ring slot and waits for GEM DMA completion. It
   publishes payload, the four-byte length/serial header, and checksum metadata
   with the required cache maintenance and ordering. It may then assert
   `desc_valid` with slot, Ethernet byte length, serial, checksum verdict and a
   32-bit cookie. Fields remain stable until `desc_ready` is sampled high.
2. Each accepted descriptor owns one bank and its backing DDR slot. The producer
   must not modify/rearm that slot, submit it again, or reuse its cookie until
   the release handshake (or completed coordinated flush). Cookies must
   distinguish sessions as well as outstanding packets. The prototype checks
   descriptor length/serial, but does not police producer slot uniqueness.
3. The module fetches header plus payload, rounded to a longword. Slots are
   2 KB aligned, so the bounded bursts cannot cross a 4 KB AXI boundary. The
   fetched header must match the descriptor. This catches a stale header; it
   does **not** substitute for payload coherency or immutable slot ownership.
4. `packet_valid` presents completed packets in descriptor order. Metadata is
   meaningful only while valid. `host_read` requests a word by address, with a
   synchronous response indicated by `host_read_valid`. Repeated/out-of-order
   reads are legal; reads beyond header plus padded payload are rejected. The
   adapter must copy only the actual payload length, excluding trailing padding.
   Data is in raw AXI byte order; the Zorro adapter must perform the existing swap.
5. `ack_valid && ack_ready` consumes the packet identified by `ack_cookie`.
   A simultaneous read is suppressed. Wrong/stale cookies do not consume the
   head. A release record preserves slot, cookie and error state until the
   producer accepts it. Backpressure on that record prevents another ACK from
   overwriting it. The freed bank can accept a different reserved slot while
   release is pending; the old DDR slot remains owned until release acceptance.

Valid lengths are 14..2044 bytes and serials are 2..65535, matching the current
2 KB slot/header format. Invalid descriptors complete as error records without
DDR reads. An AXI error, early/late RLAST or header mismatch drains the current
burst, then presents an error record with no readable data. The host must
explicitly ACK/drop it so the producer receives an error release. A missing
RLAST cannot safely be timed out and forgotten.

## Reset contract

There is exactly one outstanding AXI burst. ARVALID/address/length remain stable
until handshake. A logical `flush` immediately hides the packet banks and
cancels their logical contents, but preserves any stalled AR request and drains
all accepted responses through RLAST. It does not issue another request.
`flush_done` pulses only once the port is idle. No time-based cancellation is
used, including when an old tail is delayed more than 10 microseconds.

With the shared-port model below, "idle" here means this packet-fetch client's
requests have drained. Foreground traffic may already be using the physical
port when `flush_done` arrives; packet cancellation must not reset that traffic.

The producer/host adapter must coordinate flush: stop submissions, discard host
operations from the old session, request flush, and wait for `flush_done`
before reclaiming all old descriptors/slots and starting a new cookie epoch.
Pending release records are part of that bulk cancellation, so producer and
adapter must not independently treat a disappearing release as completion.

`aresetn` is different: it resets both this master **and its AXI interconnect**.
The slave model likewise cancels responses for this reset. Do not connect an
Amiga-only reset to `aresetn`; such a reset must use logical flush. Fabric reset
has priority over all packet-state operations and logical flush.

## Integration work before any hardware candidate

The [standalone Vivado probe](OOC.md) measures the packet core's memory inference,
resources and timing under explicit boundary assumptions. Its runner generates
no image and cannot establish full-design timing or hardware performance.

The standalone AXI master is a simulation harness boundary, not an additional
master to wire onto the live `m00` signals. In the real design, packet fetches
must be a client of the single-owner `m00` engine from the corrected read-ahead
work. Preserve exactly-once AR handshake, response ownership, logical drain and
fabric-reset priority, including the combined-reset regression. Use the existing
Zorro-pin testbench to check RX alongside framebuffer, register and other reads;
those clients must not starve behind prefetch.

### Offline shared-port arbitration model

`experimental/zz_eth_read_arbiter.v` places the packet core behind a single
physical AXI read owner, alongside an independent foreground client. This is
an executable integration contract, not a second engine to attach in parallel
with the existing m00 engine. Both clients use 32-bit reads and must keep their
request fields stable through handshake; only one transaction is admitted at
a time. Responses are routed exclusively to that transaction's client through
the accepted RLAST, including response backpressure and logical flush.

Foreground ARVALID wins every idle arbitration. `foreground_pending` reserves
an idle port for an imminent foreground AXI read even before its ARVALID is
asserted. This signal must mean a **demand DDR transaction**, not any unfinished
Zorro cycle. In particular, a read of an empty packet bank must permit the
prefetch that will supply its data. Feeding that bank wait into
`foreground_pending` creates a circular wait; the negative control reproduces it.

Once background ARVALID has been offered to the interconnect, a new foreground
arrival cannot replace it, even if ARREADY is still low. The offered address
and its response remain owned through RLAST. Prefetch is limited to 16-beat
bursts by the packet core; a waiting foreground read therefore wins after at
most the one already-selected background burst. This is a transaction-count
bound, **not a time bound**: AXI may delay ARREADY/RVALID indefinitely. Continuous
foreground demand can starve prefetch, by design; future integration must avoid
permanently asserting the demand hint and must measure progress under real load.

The model has no logical-reset input: clients drain/discard their own operations.
Shared `aresetn` resets the owner, both clients and the interconnect together.
All signals are in one clock domain. The owner captures each client's ARCACHE,
ARPROT and ARID alongside its address, length and burst type; these remain stable
through a stalled address handshake. RID is passed back unchanged, with RVALID
exclusive to the selected owner. Ownership, not RID, selects the response client;
clients remain responsible for checking their expected RID. `ID_WIDTH` defaults
to 1, matching the current m00 port, and is also tested at width 2.

Integration must retain the live m00 attributes and fixed sidebands, including
its current ARCACHE `0xf` policy. The testbench uses deliberately distinct client
attributes to detect crossed routing; they are **not** proposed production cache
or protection settings. Passing these tests makes no cache/coherency claim.

Required adapters and decisions:

* ARM producer: publish immutable completed descriptors, consume releases, and
  account for prefetched/host-owned slots in the existing GEM reservation and
  backpressure calculations. Keep the L2 publication protocol until a measured,
  justified coherent memory path replaces it.
* FPGA control and CDC: transfer each descriptor atomically, carry release/error
  records, and coordinate flush/epoch changes across clock domains. The current
  68k-to-ARM serial ACK alone is not a two-packet descriptor protocol.
* Host ABI: negotiate capability; retain the legacy path when unsupported. Map
  packet status, cookie, metadata and the addressable bank; define atomic cookie
  reads/writes on the 16-bit register interface. This core's 32-bit cookie must
  not be silently truncated to the legacy 16-bit serial.
* Driver: drain readable banks and ACK by cookie; handle error records without
  delivering their data. A later batched-release optimization is separate.
* Vivado: confirm two bank RAMs infer as block RAM with the synchronous read
  interface, report actual resource use and routed setup/hold margin. Existing
  read-ahead builds reportedly have very little timing margin; source attributes
  do not prove feasibility at the target clock.
* Hardware comparison: use the same intended zorro3-nofast variant on the
  A3000/TF4060 for both control and candidate. Preserve source, effective defines,
  bitstream/image hashes and rollback identity. Measure window read timing,
  throughput, sender retransmissions/RTT, CPU cost and boot repeatability.

This branch adds no memory-map constants, runtime registers, driver changes or
build-system inclusion. It is not a replacement for the working image.

## Reproducing the simulation

Requirements: Icarus Verilog 13.0 (tested) and Python 3 for RTL tests, and Clang
with address/undefined-behavior sanitizers for the ARM helper. Run from any directory:

```sh
python3 test/eth_packet_window/run.py
python3 test/eth_packet_window/run.py --shared-port --id-width 1
python3 test/eth_packet_window/run.py --shared-port --id-width 2
python3 test/eth_packet_window/run.py --mailbox
python3 test/eth_packet_window/run_arm.py
```

The runner uses a temporary directory under `test/eth_packet_window` and removes
it even if compilation or simulation fails. `--iverilog`, `--vvp`, and `--ivl-dir`
allow a task-local extracted toolchain without installing system packages.

The independent AXI slave checks request size and 4 KB boundaries and supplies
address-indexed expected packet data. Tests cover both banks filling before the
first ACK, complete payload comparisons, repeated/out-of-order reads, bounds,
ring and serial wrap, odd payload length, stale ACK, release backpressure,
SLVERR, stale header, early/late RLAST, invalid descriptors, stalled AR through
logical reset, a 25 us delayed tail, combined logical/fabric reset, and fabric
reset mid-burst. A filled window must not issue further DDR reads while the
host repeatedly reads it. Simulation does not model caches, CDC, Zorro pins,
the ARM driver, placement/routing, or end-to-end network throughput.

The shared-port run adds an independent foreground master and checks priority
both with an advance demand hint and when both requests arrive at the same idle
selection edge without that hint. It also checks a late foreground arrival
between packet-fill bursts, response backpressure, preserved request attributes
and response IDs, a stalled background address despite changes to the inactive
client, a 25 us discarded tail before a foreground read, bank-window reads
waiting on their own prefetch, and fabric reset with a foreground request pending
behind background traffic. It then reruns every packet-core case through that
shared owner.

Icarus 13.0 results for this follow-up: direct run has 7 case groups and passes
386 requests / 5,932 response beats / 39 releases. Shared runs at both ID widths
have 12 case groups and pass 445 requests / 6,750 response beats / 43 releases.
Four temporary negative controls each fail the intended assertion: crossing
background ARCACHE with the foreground value, replacing foreground RID with
zero, granting background over simultaneous foreground demand, and truncating
background ARID to one bit in the two-bit configuration. These mutations are
not part of the source or build. Earlier `7b852b90` controls also detected an
ignored demand hint and a bank-window wait incorrectly blocking its own
prefetch. No additional hardware measurements were made.
