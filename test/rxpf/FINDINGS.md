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

## Exact artifacts and conditions (both arms)

| item | value |
|---|---|
| candidate BOOT.bin | `BOOT-rxpf-b9c0af5.bin` sha256 `31f5fb1ac2bbaed8f1a248249087964781a99128e42586b7bbbdee22bc3ee66f` |
| candidate bitstream | `rxpf.bit` sha256 `b8e357627aa7873972e7d813eec9f433c9edaacfb9cf1af76ea5a3e6e5ea8cdf` |
| control BOOT.bin | `BOOT-upstream-all.bin` sha256 `1c17006018eb6ed1c829a281b8cd1fc139f7e91a684e14c309ba93aca1be6427` (restored with `ZZFwUpdate RESTORE -y`) |
| ARM firmware (both) | `ZZ9000OS.elf` sha256 `e6d96168d1ff33f3e38507a2accd4d5d336855c7b5dd3b3704a2847cc2b58455` (upstream/all 6aeab1c build) |
| 68k driver (both) | `anxzz9000.device` sha256 `fdbc7a98fa83111415b1caf7b59e6197d648bd95a60e2f0588f73b08d2980e65` (AmiNetXDuo main bf215f5c) |
| interface file (both) | `DEVICE=AmiNetXDuo:Devs/Networks/anxzz9000.device UNIT=0 CONFIGURE=DHCP MDNS=YES` |
| load | the card loaded each image on a flushed 30 s shop power cut; control measured before the candidate flash and again after the restore (21.7 both times) |
| traffic | peer playhouse4 (192.168.1.160, same TL-SG1016PE switch) sends iperf TCP to the ZZ9000 address, `--seconds 15 --length 65536`, Amiga side `AmiNetXDuo:C/iperf -s -t 30`; 3 runs per arm; switch port flow control on for the X-Surf port (16) |
| other interface | X-Surf 100 up on the same A3000 throughout (its own RX 21.8 on the candidate boot) |

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
2. ~~Stale L2 lines past a short frame~~ -- **ruled out by reading the
   firmware.**  `ethernet.c` (publish, ~line 850) drops from L2 every line
   the new frame covers (offset 32 .. rx_bytes + RX_FRAME_PAD), then writes
   the header and drops its line.  A line a burst allocated beyond an earlier
   short frame is invalidated before a longer frame can expose it; lines
   beyond the current frame are never read by the driver.  Bursts issued
   while the 68k polls an empty slot fill from DDR the GEM has not yet
   written, and those lines are dropped by the same publish.
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
