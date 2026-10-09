# Receive-window read-ahead: hardware result (2026-10-08)

Status: **DO NOT FLASH.  On its 7th power-up this bitstream left the A3000
unable to boot (white screen flashes, then black); the user restored an older
image by hand.**  Before that: bimodal per boot.  Window reads are faster on every boot; end-to-end
receive is +8.7 % on some boots and collapses to 3.4 Mbit/s on others.  Not for
merging until the slow state is explained.  (Update 2026-10-08 23:35Z below.)

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
- ARCACHE belongs to the whole AR transaction, so "allocate only the demand
  beat" is not one burst: either split it (a single-beat allocating read for
  the demand word, then a non-allocating burst for the rest) or make the whole
  burst non-allocating -- noting the 22-09 ARCACHE A/B, where non-allocating
  window reads were 8 % slower.  Or fill the line from a non-ACP port.
- Count, in the firmware, the time from GEM completion to frame presentation
  under both images.

Reproduce in simulation: `test/rxpf/run.sh` (Vivado 2018.3 xsim).  It runs
four arms -- steady, random ARREADY, ragged (5-68 cycle latency per burst,
random gaps between beats), ragged with random ARREADY -- and exits non-zero
unless every arm prints its verdict.  Not modelled yet: RRESP other than OKAY,
and ARM-side S_AXI register traffic (slot changes arrive as a direct write to
slv_reg4) while a burst is in flight.


## Update 2026-10-08 23:35Z: the slow state is per boot, not per image

Reflashed the same `BOOT-rxpf-b9c0af5.bin` and power-cycled (flushed, 30 s)
four times, one iperf RX via the ZZ9000 per boot (3 on boot 2).  Window read
timing (452 ns/long) confirmed the candidate on every boot checked.

| boot | IPv4 lease | RX Mbit/s | sender RTT | sender snd_wnd (1 s samples) |
|---|---|---|---|---|
| 1 | > 60 s | 3.39 / 3.42 / 3.41 | 198-216 ms | 80288 every sample |
| 2 | < 10 s | 23.57 / 23.55 / 23.55 | 9.2-10.0 ms | 6912-60736, varying |
| 3 | 2 s | 3.44 | 199 ms | 80288 every sample |
| 4 | 3 s | 23.66 | 10.6 ms | 41952-80288, varying |
| control (upstream/all), 2 boots | -- | 21.6-21.7 | 10.1-12.5 ms | 25888-62368, varying |

Good boots are **+8.7 %** over the control.  The slow lease on boot 1 was a
coincidence (boot 3 leased in 2 s and was still slow).

**Sender pcaps** (playhouse4, headers only, `ackscan.py`), control vs good boot 2:

| | control | candidate, good boot |
|---|---|---|
| throughput in the capture | 21.43 Mbit/s | 23.35 Mbit/s |
| ACKs (advancing / other) | 1230 / 662 | 1332 / 717 |
| inter-ACK gap p50 / p90 / max | 10.7 / 14.7 / 19.0 ms | 9.6 / 13.3 / 17.8 ms |
| bytes acked per ACK p50 | 35040 | 36500 |
| RTT samples p50 / p90 | 12.5 / 15.3 ms | 11.4 / 14.1 ms |
| retransmitted-looking segments | 67 | 70 |

Same ACK pattern, slightly faster; no gap over 150 ms in either.

**The slow boots** look like the receiver acknowledging only on a ~200 ms
timer: a constant full window (80288), 55 segments always in flight
(55 x 1460 B / 0.2 s = 3.2 Mbit/s, the observed rate), no loss.  68k-side
counters, slow boot 1 vs good boot 2 (after equal-length runs):

| | slow boot 1 | good boot 2 |
|---|---|---|
| serial gaps (ARM ring overflow) at boot | 11 | 0 |
| TCP segments after GRO, bytes each | ~4.3 KB | ~16.5 KB |
| packets sent per received frame | ~1 : 3 | ~1 : 15 |
| bad data / checksum / drops | 0 | 0 |

So in the slow state the stack merges far fewer segments per GRO run and sends
many more packets, yet the sender sees ACK progress only every ~200 ms.  The
deciding state may be in the stack's GRO / ACK pacing, latched by early
timing after boot, rather than in the read-ahead itself; the slow state has
not been seen on the control image (2 boots only -- not enough to exclude it).

Next: a slow-boot sender pcap (cycling until one is caught), then codex's
proposed builds with `rxpf_beats` forced to 1, 4, 8.


## Update 2026-10-09: boot hang -- the image is unsafe

Boots 5 and 6 were good (23.56 Mbit/s each; tally 4 good, 2 slow of 6).  On the
7th flushed power cycle (2026-10-08 23:38Z) the A3000 never came up: per the
user, **white screen flashes at startup, then a black screen, no boot**.  No
ARP from either interface.  The user restored an older ZZ9000 image by hand;
afterwards the receive window reads 567 ns/long (no read-ahead) and the
machine boots normally.

So the candidate has a power-up dependence that reaches beyond Ethernet: the
RTG/video side failed to come up on that boot, and on other boots the network
path lands in the 200 ms ACK-timer state.  The read-ahead changes only the m00
read path, so the leading suspects are power-up conditions it touches: the
registers it adds without a reset term other than Zorro reset (`rxpf_busy`
can only clear on RLAST), arlen/arburst moved out of the defaults block and
now set only in the Z2/Z3 read states (undefined until the first read), and
any m00 burst issued before the PS/ACP side is up (the 68k probing the card
during its own boot).  Nothing here is verified.
