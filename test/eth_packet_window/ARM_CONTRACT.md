# ARM packet ownership integration contract

`experimental/zz_eth_rx_lease.h` is a portable, tested ownership helper, outside
all firmware builds. It supplies neither a register map nor a CDC transport.
`rx_lease_test.c` runs it with cache-publication callbacks on the host. Those
callbacks test ordering; they do not emulate PL310 coherency, GEM DMA or IRQs.
The existing RTL tests and this C test are separate, not an end-to-end cosimulation.

The source anchors below refer to `ethernet.c` at firmware commit
`efc04df280286b3f0091a0cd609dda9032030624`, under
`ZZ9000_proto.sdk/ZZ9000OS/src/`. The helper deliberately leaves that file alone;
zz9k-fpga owns the separate DMA-restart/IRQ exclusion fix and its validation.

## Existing accounting must continue to own the DDR ring

`ethernet_backlog_pending()` (line 428) counts `frames_backlog` plus
`frames_backlog_reserved`. The latter counts GEM reservations, not FPGA leases.
Preparing a GEM BD reserves a DDR slot (line 685). DMA completion moves that
reservation into the completed backlog (lines 813–859). A completed packet must
stay in `frames_backlog` while offered, prefetched, presented to the host, or
waiting for its FPGA release to reach ARM. Moving it to an FPGA bank must not
subtract it from backlog, or add it again to reserved.

The helper overlays those counters with per-slot state and an ordered lease
queue. It does not allocate BDs or recompute pressure. `count` is the number of
offered or unretired leases, a subset of completed backlog. It must not be added
to `ethernet_backlog_pending()`. The current high/low watermarks stay unchanged
until measured evidence warrants a different policy.

Every call, its surrounding ring-counter update, and the transport consumer
must share an IRQ-excluded critical section. The existing comments at
`ethernet_pause_rx_irq()` (line 448) explain why masking GEM RX interrupt bits
alone is insufficient. The helper has no internal locks and callbacks must not
reenter it. Merely adding `volatile` does not provide mutual exclusion. Use an
adapter with defined IRQ save/restore and nesting behavior; do not assume the
current pause/resume pair provides a general nestable lock.

## Publish, offer, accept, release, retire

1. After DMA completion, process completed slots in ring order. Call
   `zz_rx_lease_prepare()` only for the next unleased completed slot. It rejects
   a pinned slot, invalid metadata, a second pending offer, and exhausted cookies
   before invoking publication callbacks. The legacy consumer and packet-bank
   consumer must not run concurrently on this ring.
2. Map the publication callbacks to the existing protocol at lines 850–856:
   invalidate/synchronize payload lines starting at byte 32, write the four-byte
   big-endian length/serial header, then invalidate/synchronize its first line.
   That line includes the first 28 payload bytes. For frames of at most 28 bytes,
   the first-line operation covers the entire frame. Both invalidations retain
   `ethernet_backlog_slot_publish_from()` completion/DSB semantics. Callback
   return must mean completion, not just enqueueing cache work.
3. Only after those callbacks finish does `zz_rx_lease_offer()` expose the whole
   immutable descriptor: slot, length, serial, checksum verdict and 32-bit cookie.
   The C structure's padding/layout is **not a wire format**. Future transport
   must encode fields explicitly and commit them atomically; neither a partial
   MMIO write nor setting a valid flag before the payload is sufficient.
4. Call `zz_rx_lease_accept()` exactly once after the transport durably accepts
   the complete descriptor. Process that acceptance before any returned release.
   If the transport stalls, preserve the staged descriptor and backing DDR.
   Copying to a mailbox is insufficient unless its acceptance protocol guarantees
   ownership and delivery. Any transport queue is part of the lifetime fence.
5. Host ACK and FPGA fill completion do not retire a DDR slot. Consume the FPGA's
   release record and call `zz_rx_lease_release(slot, cookie, error)`. A wrong,
   duplicate, unaccepted or stale identity is rejected. Error releases follow
   the same ownership rule, while their packet data must not reach the stack.
6. `zz_rx_lease_retire()` returns only the contiguous released prefix in offer
   order. Verify the returned slot is the current `frames_backlog_read`, advance
   that head, decrement `frames_backlog` once, and clear exactly the retired slot
   within the same critical section. Then apply existing low-watermark/refill
   logic. Do not call the legacy `ethernet_receive_frame()` serial/bare-ACK path:
   it can clear a slot before the new release protocol permits reuse. Do not
   clear a following, still-pinned slot as an empty-window convenience.

Two FPGA banks do not imply that ARM can track only two records: a bank becomes
free when ACK creates a release, before ARM accepts that release. Another slot
can occupy the bank while the older release is in flight. The helper tracks all
128 possible DDR slots, without inventing another bank-credit mechanism. The
transport's actual ready/accept handshake governs admission to the two banks.
Its queue may be much smaller than the ledger; tests filling the ledger are
boundary tests, not claims that hardware can hold 128 bank descriptors.

## Coordinated reset and cookie lifetime

`zz_rx_lease_init()` is for initial startup after a common reset fence across
GEM, host, FPGA and transport. Do not reinitialize the helper for an Amiga-only
reset or repeat DMA setup while the old session can still send commands.

`zz_rx_lease_flush_begin()` stops new offers and freezes retirement. All old
slots stay pinned, including a descriptor staged or queued but not yet accepted
by the FPGA. This is a software staging API, not a direct ready/valid wire;
the transport must preserve already-offered transactions until their own
acceptance/cancellation fence. Late accepts/releases during cancellation belong
to the old session and are covered by bulk cancellation, not normal retirement.

`zz_rx_lease_flush_finish()` requires all four externally established facts:

* **CORE_DRAINED:** the logical flush completed after the packet client's stalled
  AR and accepted responses drained. A timeout or an Amiga-only reset is not a
  drain. For a full fabric reset, the whole AXI path must be reset together.
* **LINKS_DRAINED:** descriptor, ACK, release and control transports have cancelled
  or drained all old records and acknowledged their reset. FPGA `flush_done`
  does not prove this, and cannot prevent a queued old descriptor arriving later.
* **GEM_QUIESCED:** DMA and interrupt handlers can no longer write old slots or
  change their accounting while the ring is rebuilt.
* **HOST_QUIESCED:** no old packet read, ACK or multiword control operation can
  reach the next session. Invalidate any host metadata snapshot.

These flags are assertions by the adapter after real handshakes, not mechanisms
that perform those waits. Until all are true, no slot becomes reusable. After
completion, rebuild the GEM/ring state under the same exclusion, then enable
transport/submission and host access in the new session. No simultaneous old
release and bulk-cancellation path may decrement the ring twice.

Cookies are monotonically allocated across logical resets; the legacy serial
may wrap independently. A 32-bit cookie is never silently recycled. After
`UINT32_MAX`, preparation fails closed (including after a logical flush), allowing
existing leases to release/drain. A planned, coordinated session reinitialization
with every fence above is required before restarting the sequence. The eventual
host ABI needs a capability/session handshake and must preserve the entire
cookie across its 16-bit register interface. That ABI remains unassigned.

## Validation and remaining integration

Run `python3 test/eth_packet_window/run_arm.py` with Clang. Four groups cover cache
callback order and first-line boundaries, invalid metadata, immutable stalled
offers, exact release identity, reordered/error/duplicate releases, contiguous
retirement, pending and accepted descriptors across incomplete reset fences,
stale releases after reset, full-ledger pressure, repeated ring wrap and cookie
exhaustion. The runner enables warnings as errors and address/undefined-behavior
sanitizers, and removes its temporary executable on success or failure.
Temporary negative controls also verify that the tests reject wrong-cookie
acceptance, retirement before release, an incomplete reset fence, resetting the
cookie allocator on logical flush, and publishing the header before payload.
Those mutations are not part of the published source.

Required next work is an atomic descriptor/release transport with CDC/reset
acknowledgements, explicit host capability and snapshot/ACK registers, integration
with the corrected GEM restart path, and tests linking this helper to the actual
RTL and Zorro driver. This helper neither proves a hardware throughput gain nor
supplies Vivado BRAM inference/resource/routed-timing evidence.
