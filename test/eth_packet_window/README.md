# Packet-sized FPGA receive-window prototype

Status: **offline experiment, not integrated into any firmware build**. No image
was built or flashed for this prototype. Neither Vivado block-RAM inference nor
resource usage, routed timing, clock-domain crossings, or hardware performance
has been verified. The existing nofast control/read-ahead experiment is separate.

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
