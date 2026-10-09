# Packet-sized FPGA receive-window prototype

Status: **offline experiment, not integrated into any firmware build**. No image
was built or flashed for this prototype. Neither Vivado block-RAM inference nor
resource usage, routed timing, clock-domain crossings, or hardware performance
has been verified. The existing nofast control/read-ahead experiment is separate.

The initial packet core at `e81420cc` received an independent source review from
zz9k-fpga: no core correctness blocker found; tests were not independently rerun.
Two RAMB18s is the reviewer's area estimate, not measured synthesis. The current
follow-up adds an isolated foreground/prefetch arbitration model and tests; it
still does not modify the live m00 engine or its Zorro-pin testbench.

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
All signals are in one clock domain. Cache/protection attributes must retain
the live m00 contract when integrating; this model routes address, length, burst
and response signals only and makes no cache/coherency claim.

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

Requirements: Icarus Verilog 13.0 (tested) and Python 3. Run from any directory:

```sh
python3 test/eth_packet_window/run.py
python3 test/eth_packet_window/run.py --shared-port
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
before prefetch launch, a late foreground arrival between packet-fill bursts,
response backpressure, a stalled background address and 25 us discarded tail
before a foreground read, bank-window reads waiting on their own prefetch,
and fabric reset with a foreground request pending behind background traffic.
It then reruns every packet-core case through that shared owner.

Icarus 13.0 results for this follow-up: direct run 386 requests / 5,932 response
beats / 39 releases; shared run 442 requests / 6,732 response beats / 42 releases.
Two temporary negative controls were also checked: removing the demand-priority
hint fails the priority assertion, and incorrectly treating a bank-window wait
as foreground demand times out waiting for packet 904. These mutations are not
part of the source or build; they establish that the tests detect those wiring
errors. No additional hardware measurements were made.
