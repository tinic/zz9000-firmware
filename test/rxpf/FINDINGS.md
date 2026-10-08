# Receive-window read-ahead: hardware result (2026-10-08)

Status: **regression on hardware, reverted on the bench.**  The read path is
faster; end-to-end receive collapses.  Pushed for review, not for merging.

## Setup

- A3000, TF4060 68060/50, Super Buster rev 11, Kickstart 3.2.
- ZZ9000 with `upstream/all` 6aeab1c (`BOOT-upstream-all.bin`, sha256
  1c17006018eb6ed1...) as the control; candidate = that tree + b9c0af5,
  same ARM `ZZ9000OS.elf`, built with Vivado 2018.3 (TIMING_GATE PASS,
  overall setup +0.001 ns, hold +0.017 ns), `BOOT-rxpf-b9c0af5.bin` sha256
  31f5fb1ac2bbaed8...
- Driver: AmiNetXDuo `anxzz9000.device` (main bf215f5c, multicast hash).
- Timing tool: a read-only E-clock loop (word / long / movem.l reads, and
  move.l / movem.l copies into TF4060 RAM), best of 3-5, under Forbid().
- Throughput: iperf, peer on the same switch -> the ZZ9000 address, 3 x 15 s.

## Numbers

| | control | read-ahead |
|---|---|---|
| receive window `$48002000` read, per longword | 569 ns | **452 ns** |
| receive window -> RAM copy, per longword | 679 ns | **571 ns** |
| card memory outside the window (`$4C000000`) | 574 ns | 574 ns (unchanged, as designed) |
| iperf receive via ZZ9000 | 21.7 Mbit/s, RTT 10-12 ms | **3.4 Mbit/s, RTT ~200 ms** |
| iperf receive via X-Surf (same boot, control for the machine) | 21.8 | 21.8 |

On the candidate, after ~13k received frames: bad data 0, overruns 0, receive
errors 0, TCP/UDP checksum errors 0, retransmits counted by the Amiga stack 0,
"serial gaps (ARM ring overflow)" 11 (present right after boot, did not grow),
interrupts claimed 9970, at most 8 frames per pass, no polled pass ever found
frames.  So frames arrive intact as far as the 68k can tell, but late.

## What is not understood

1. **Why the round trip goes to ~200 ms.**  The 68k side handles every frame
   on its interrupt; the delay is elsewhere -- the ARM presenting frames late,
   or the GEM/ARM path slowed by the bursts.
2. **ACP + L2.**  The m00 read path is on S_AXI_ACP with ARCACHE 0xf, so a
   16-beat burst allocates up to 60 bytes past what the 68k needs into the
   PL310 L2.  The firmware invalidates a slot's L2 lines when it publishes a
   frame; if it invalidates only the frame's length, lines allocated past the
   end of a short frame could serve stale bytes when a longer frame later uses
   the slot.  The driver trusts the GEM checksum verdict, so stale payload
   would not be counted anywhere.  **Unverified, and a correctness risk**:
   check `ethernet.c`'s invalidate range before trusting any read-ahead here.
3. Whether 16 x 32-bit INCR bursts on the ACP stall the ARM's own DDR/L2 work
   enough to delay frame presentation (the 22-09 ARCACHE experiment showed
   this read path's cache attributes do change ARM-side throughput).

## Ideas for a second look

- Burst only within the current frame's length (the length word is the first
  beat of the slot) instead of a fixed 16 beats.
- Non-allocating ARCACHE for the burst beats beyond the requested word, or a
  read-ahead buffer filled from a non-ACP port.
- Count, in the firmware, the time from GEM completion to frame presentation
  under both images.

Reproduce in simulation: `test/rxpf/run.sh` (Vivado 2018.3 xsim).
