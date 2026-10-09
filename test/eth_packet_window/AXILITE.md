# Experimental AXI-Lite mailbox transport

`experimental/zz_eth_packet_axilite.v` joins the registered [mailbox](MAILBOX.md)
to a 32-bit AXI-Lite interface, in the same FCLK0 100 MHz domain. It is an offline
component, not connected to the live design. Its addresses are **relative byte
offsets**, `4 * mailbox word`, from 0 through 36. `ADDR_WIDTH` must be at least 6;
the default is 12 so simulations can also detect aliases through high address bits.

## Accepted transactions and results

AW and W each have one independent holding register. Either may arrive first;
address, data and WSTRB are captured only on their respective handshakes. Once
both halves are held, the adapter emits one CSR write pulse and creates one B
response. BVALID/BRESP remain stable until BREADY. No second write is admitted
until that response retires. This conservative adapter does not target one write
per clock; descriptor bus bandwidth and resulting packet throughput are unmeasured.

AR captures a read snapshot into RDATA/RRESP, held unchanged until RREADY. Reads
and writes progress independently, with at most one read response and one write
transaction in flight. A read accepted on the same edge as a CSR write sees the
pre-write register state. Firmware must finish the write and enforce its MMIO
ordering before reading LAST_RESULT. RVALID backpressure must never expose later
changes in a release snapshot, STATUS or LAST_RESULT.

Unaligned or out-of-range addresses complete with SLVERR (and read data zero).
Invalid writes never pulse the backend, so LAST_RESULT is unchanged. Full-width
address comparison prevents an upper address bit from aliasing a legal word.
For valid addresses, all writes return OKAY, including logical CSR rejection:
partial WSTRB, BUSY, read-only writes, bad cookies and bad mode are reported by
LAST_RESULT. OKAY alone does not prove COMMIT or POP succeeded. Unimplemented
read directions of valid words return zero, as defined by the backend. AWPROT
and ARPROT do not affect this local module; security/access control belongs to
the enclosing interconnect. The adapter is not an access-control boundary.

## Quiesce is not fabric reset

`quiesce_request`, `resume`, `quiesced` and `local_drained` belong to a separate
same-clock reset controller. They are not mailbox register fields. Fabric reset
starts the adapter fenced; explicit resume is required before using the bus.
Quiesce immediately prevents new AW/W pairs and AR handshakes, and latches the
fence. If one write half was already accepted, only its missing half remains
ready. That complete old write executes **normally**, even after quiesce; it is
not silently dropped or falsely acknowledged. Previously accepted R and B
responses also complete normally. No timeout clears an unpaired half or a held
response. A failed master can therefore leave drain incomplete indefinitely.

`local_drained` requires the latched fence, both write buffers empty, and no B
or R response. It does not include packet-core AXI traffic or mailbox state.
An early resume is ignored; resume while quiesce is high is ignored. After drain,
with quiesce low, explicit resume releases the fence. A high resume held through
drain is a persistent request and will take effect once the condition is met;
the controller must assert it only when the complete session can resume.

The adapter cannot distinguish old traffic that has not yet handshaken from new
traffic. An AW/W/AR VALID held upstream during local drain can be accepted after
resume. The test deliberately demonstrates this boundary. Therefore **local
drain is not the ARM helper's LINKS_DRAINED fence**, nor permission to recycle
cookies, slots, DMA descriptors or ring counters. There is no automatic reset
sequencer in this change.

A production reset sequence needs all of the following, in this order:

1. Exclude GEM IRQ/main-loop producers and old host operations, stop issuing old
   mailbox accesses, and establish the platform's upstream MMIO fence while the
   adapter is still servicing traffic. Do not strand posted whole transactions
   behind a newly closed gate. If quiesce is asserted with a half accepted, its
   remaining half and responses must still progress; local drain alone says
   nothing about additional transactions queued before the gate.
2. Assert adapter quiesce and wait for local drain. Separately establish the
   upstream guarantee that no old unaccepted request can appear after resume.
3. Use the independent mailbox `flush_request` to flush the backend/core and
   wait for actual core drain/HALTED. Already accepted writes may include COMMIT
   or REARM, so flushing before the local write drain is not a replacement for
   this ordering. Wait for the independent shared-port, GEM and host fences.
4. With all required fences established, rebuild ring/session state under GEM
   exclusion. Clear the mailbox flush level, resume the adapter, then issue and
   verify mailbox REARM. Only the reset owner may access the bus during this
   interval. Resume normal producers after successful rearm.

Control FLUSH through this AXI bus remains available while admitted, but is only
backend/core cancellation; it is not an adapter/upstream transaction fence.
`aresetn` is reserved for coordinated fabric reset of the connected endpoints
and interconnect. An Amiga-only reset must not deassert it to abandon ownership.

## Live register-map constraint

At source `17e0d272f525b9b7245a076a8141daa35afa7add`, active `mntzorro.v:38`
defines a five-bit S_AXI address, and line 358 decodes eight words. Read decode
at lines 3492-3505 uses all eight: REG0-3 status, REG4-5 diagnostics, REG6 layout
acknowledgement (write direction is FastRAM readiness), REG7 aperture size.
`ZZ9000_proto.sdk/ZZ9000OS/src/main.c:490,584` consumes REG7 at startup.
The old `ip_repo/MNTZorro_1.0` generated template is not the active module.
The block design uses a module reference (`zz9000_project.tcl:672-675`).

Ten mailbox words cannot fit in that aperture. Integration must widen and
revalidate the active module/block-design address decode or add a separate slave
and interconnect mapping; it must preserve the existing words and firmware
layout contract. No live address, capability bit or host ABI is allocated here.
The local adapter must receive relative offsets from that eventual decoder.

## Validation and limits

Run `python3 test/eth_packet_window/run.py --axilite`. Five groups connect the
adapter to the real mailbox and packet core. They cover AW-before-W,
W-before-AW, simultaneous halves, capture of changing input fields, long B/R
stalls, logical rejection versus invalid address, high-bit/unaligned aliases,
read snapshots during COMMIT, actual payload and exact release POP, both partial
write quiesce cases, pending-response drain, premature/held resume, retained
upstream VALID, concurrent read-before-write, and common fabric reset of a
partial request and held responses. Testbench monitors also enforce stable B/R,
response/request accounting and no repeated CSR strobes.

This is not a CPU/interconnect model, C-helper cosimulation, host-driver test,
full-design timing result or hardware throughput measurement. The previous OOC
measurement covers the packet core only. Combined resource/setup/hold evidence,
physical clock context, shared-m00 integration and Zorro pin tests remain open.
