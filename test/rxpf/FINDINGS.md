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


## Update 2026-10-09: two initialization flaws, reproduced in simulation and fixed

`run.sh` gained a `boot` arm modelling what an interconnect does while the PS
comes up after power-on: ARREADY that follows ARVALID one cycle late, and a
burst that delivers one beat and loses the rest (no RLAST).

| boot-condition check | upstream 2.8 source | b9c0af5 (flashed) | fixed |
|---|---|---|---|
| late ARREADY: AXI requests for one card read | **2** (both paths) | **2** non-window, 1 window | 1 |
| lost beats, then Zorro reset: card reads afterwards | ok | **hang forever** (state 54, rxpf_busy stuck 1) | ok |

1. **Duplicate read requests (upstream bug, latent).**  WAIT_READ (Z2) and
   WAIT_READ_DMA_Z3 moved on as soon as ARREADY was high and dropped ARVALID
   one state later.  If ARREADY rises one cycle after ARVALID, ARVALID is
   still high on the next edge and a second, unwanted read is issued; its
   beat arrives later and is taken by the next read as its own data.  Fixed:
   the handshake is ARVALID && ARREADY on one edge, and ARVALID drops on that
   edge.  Worth sending upstream on its own.
2. **`rxpf_busy` could stick forever (ours).**  It cleared only on RLAST; it
   had no reset and no timeout, and it intentionally survived a Zorro reset.
   A burst cut off while the PS side comes up left it at 1, and every later
   card read -- framebuffer included, since non-window reads wait for it --
   waited for ever.  This is a **plausible mechanism** for the black-screen
   boot, not a demonstrated cause: nothing shows that boot 7 actually lost a
   burst.  The first fix (60e31fa, a 10 us watchdog) was **wrong** and is
   superseded below: a timeout is not an AXI cancellation, and a slow slave's
   old beats arriving after it were taken as a later read's data.

Whether flaw 1 also explains the slow-boot state (a stray beat shifting every
later window read by one response) is a hypothesis; the fixed image has not
been on hardware.


## Update 2026-10-09: the m00 read port as a single-owner transaction (supersedes 60e31fa)

After codex's review of the watchdog:

- The port carries at most one transaction.  Its state (`m00_axi_arvalid`,
  `rd_out`, `rd_fill`, `rd_discard`) lives outside `zorro_state`, so leaving a
  Zorro cycle cannot orphan it.  ARVALID drops only on the ARVALID && ARREADY
  edge.  A new request goes out only when `rd_idle` (fabric not in reset, no
  request pending, nothing owed).
- A Zorro reset does not cancel a read -- AXI cannot -- it marks it
  `rd_discard`; the beats are drained to RLAST and dropped.
- `m00_axi_aresetn` (previously unused) clears the port outright and keeps
  ARVALID low while asserted; a Zorro cycle waiting on a read the reset took
  issues it again.
- No timeout anywhere.
- Power-up values: registers declared `= 0` and the new `initial
  m00_axi_arvalid = 0` become the flops' INIT values in synthesis (UG901), so
  they are defined at configuration; in the old code ARLEN/ARBURST being
  unassigned while ARVALID was low was not itself a bus violation.

`run.sh` boot arm, all with data checked against the AXI model:

| case | 60e31fa (watchdog) | single-owner port |
|---|---|---|
| late ARREADY: one request per read | pass | pass |
| fabric reset (aresetn) mid-burst, then reads | pass | pass |
| slow slave, 20 us stall inside a burst | pass (by luck: retried burst started at the next address) | pass |
| stalled fill, then a non-window read while the old tail is owed | **wrong data** | pass |
| request pending (ARREADY low) across a Zorro reset | **hangs, wrong data** | pass |
| slot change during a fill | pass | pass |
| SLVERR beats | pass | pass |

Limits of the testbench: autoconfig is still seeded rather than run; S_AXI
(ARM register) traffic is modelled by writing `slv_reg4` directly, not as AXI
write transactions; RRESP is passed through, not acted on.  Hardware: not yet.


## Correction 2026-10-09: every hardware result above used the wrong variant

All images built so far (`rxpf.bit` b9c0af5, `rxpf3.bit` 03a5f70, and the
`BOOT-upstream-all.bin` control) had `VARIANT_Z3_FASTRAM` and
`VARIANT_SUPERDENISE` defined.  This A3000 runs a TF4060 and needs the
**zorro3-nofast** variant (both undefined); the release image the user
restored is that variant.  So the bimodal boots, the boot-7 hang and the
+8.7 % all come from a configuration the machine is not meant to run, and
none of them can be attributed to the read-ahead until they are repeated on
nofast builds.  Next: c8786cc nofast and an `upstream/all` nofast control,
same ARM elf, the same flushed power-up series on each.


## Nofast A/B, 2026-10-09: the read-ahead is +9-10 %, and the slow boots are not its doing

Both images nofast (`VARIANT_Z3_FASTRAM` and `VARIANT_SUPERDENISE` off), same
ARM `ZZ9000OS.elf` (e6d96168...), same driver.  Candidate c8786cc
(`BOOT-rxpf-c8786cc-nofast.bin` c649517b..., TIMING_GATE setup 0.000 / hold
0.015 ns); control `upstream/all` 6aeab1c (`BOOT-upall-nofast.bin`
66673085..., setup 0.091 / hold 0.050 ns).  Six flushed 30 s power cycles
each.  Per boot: window timing and one iperf RX at 50 MHz, then `cpuspeed 86`
from the shell (the TF4060 reports 82 MHz; never in Startup-Sequence), then
timing and RX again.  Counters are cumulative over both runs.

| boot | window ns/long (50 MHz) | RX Mbit/s 50 MHz | RX Mbit/s 82 MHz | serial gaps | dropped for size |
|---|---|---|---|---|---|
| rxpf 1 | 452.1 | 23.5 | 28.4 | 0 | 0 |
| rxpf 2 | 452.1 | 23.6 | 28.4 | 0 | 0 |
| rxpf 3 | 452.1 | 23.7 | 28.4 | 0 | 0 |
| rxpf 4 | 452.1 | 23.5 | **24.6** | 1 | 1 |
| rxpf 5 | 452.1 | 23.6 | 28.4 | 0 | 0 |
| rxpf 6 | 452.5 | 23.6 | 28.2 | 0 | 0 |
| upstream 1 | 565.4 | 18.6 | 21.2 | 0 | 1 |
| upstream 2 | 566.4 | 21.7 | 26.1 | 0 | 1 |
| upstream 3 | 566.4 | 21.6 | 25.9 | 0 | 1 |
| upstream 4 | 567.1 | **3.4** | **3.4** | 4 | 0 |
| upstream 5 | 566.7 | 21.5 | 26.0 | 0 | 0 |
| upstream 6 | 565.4 | 21.7 | 25.9 | 0 | 0 |

- Every power-up of both images came back; no hang on nofast.
- Clean boots: read-ahead 23.5-23.7 vs 21.5-21.7 Mbit/s at 50 MHz (+9 %),
  28.2-28.4 vs 25.9-26.1 at 82 MHz (+9 %).  At 82 MHz a window read takes
  longer in ns (494 vs 452 on rxpf) yet RX is +20 % over 50 MHz.
- **The 3.4 Mbit/s / ~200 ms state occurs on the upstream image (boot 4).**
  It is a pre-existing problem, not caused by the read-ahead.
- Size drops occur on clean upstream boots (1-3) with normal throughput: not
  a read-ahead artifact and not the marker of the bad state.
- **Serial gaps (frames the ARM dropped) mark the bad boots in both arms**
  (rxpf 4: 1, upstream 4: 4; the old fastram slow boot: 11).  Every clean
  boot has 0.

Slow state (upstream boot 4, `ackscan`): ACKs every 10.9 ms (p10-p90
10.4-11.4), each covering exactly 3 segments (4380 B), RTT 196 ms, no
retransmissions, window always full.  So frames are not ACKed late; they
**queue ~200 ms (~55 frames, the whole window) and drain at ~280 frames/s**.
The degraded rxpf boot 4 was a milder form: ACKs every 14 ms covering 30
segments, 28 ms RTT, almost no window-update ACKs.

The 68k driver only counts a gap (`zz_rint`), it changes no state, so the
latch is not there.  Firmware candidates (`ethernet.c`): a drop still
consumes a serial; backlog over the high watermark sets `rx_backpressure`
and sends 802.3x PAUSE, cleared only from the 68k ack path; and the
full/slot-mismatch drop branch clears the slot without advancing
`frames_backlog_write` while the reserve pointer has moved on.  Next:
sample the ARM's RX status register (`zzrxs`: ready/reserved/backpressure/
drops/PAUSE every 20 ms) during the RX run until a slow boot is caught.

**Hypothesis (02:00Z, unverified): the slow state is a latched PAUSE storm.**
`ETH_PAUSE_QUANTUM` is 0x0800 = 2048 x 512 bit times = 10.49 ms at 100 Mbit/s;
the slow boot's ACK clock is 10.9 ms (p10-p90 10.4-11.4).  The ARM sends a
PAUSE from `XEmacPsRecvHandler` whenever `pending = frames_backlog +
frames_backlog_reserved >= 120` (HIGH; LOW is 96).  If a drop path leaks
that accounting by ~56 entries, pending never falls below HIGH even with
the 68k drained, every RX interrupt re-pauses the switch, and ~3 frames get
through per pause window (~280 frames/s, as observed).  The drops are what
the 68k sees as serial gaps.  To verify: `zzrxs` on a slow boot should show
`ready` or `reserved` stuck high with the window empty, and `pause` rising.

ARM RX state on a clean upstream boot (ctl-8, `zzrxs` 700 x 20 ms during the
50 MHz run): ready 0 (697) / 1 (3), reserved 64, backpressure never, ARM drops
>= 255 (8-bit field saturated) and 203 PAUSE frames sent, both static for the
whole run.  So every boot drops and pauses while nobody drains the backlog
before the driver attaches; the 68k counts none of that as a gap, since its
serial tracking starts at 0.  Note (codex): a serial gap is evidence of loss,
not proof of the latched cause; `zz_rint` only counts forward gaps, and the
repeat/older-serial `ACK_RECOVER` path is a separate mechanism.

## Slow state CONFIRMED on hardware (ctl-10, upstream nofast, 2026-10-09 02:08Z)

`zzrxs` on the slow boot (3.44 / 3.40 Mbit/s, RTT 207 / 210 ms), 700 samples
per run: **ready 0, reserved 116-119, backpressure set in 700/700**, PAUSE
counter saturated (255).  On clean boots reserved is 64 (= RXBD_CNT, the
physical maximum) and backpressure is never set.  So `frames_backlog_reserved`
has leaked by ~53 above the descriptors that exist: pending can never fall
to LOW (96), backpressure never clears, `ethernet_alloc_rx_frames()` arms
only the 1-3 descriptors that fit under HIGH (120), and each arrival
re-sends a 10.49 ms PAUSE, giving ~3 frames per pause (= the 10.9 ms ACK clock).
68k: 8 serial gaps, 0 size drops, 0 ACK recoveries.

Root cause (source reading, consistent with the above): `ethernet_reset_for_
amiga()` runs on every Amiga reset, i.e. every boot.  In ETH_TASK_READY it
calls `ethernet_restart_dma("amiga-reset")`, which runs Stop /
`ethernet_clear_host_state()` (reserved = 0) / `init_ethernet_buffers()`
(reserved += 64) **without** `ethernet_pause_rx_irq()`; only the not-ready
branch masks the GEM line.  `XEmacPs_Stop()` does not mask the GIC, so a
frame landing in that window runs `XEmacPsRecvHandler()` on the old ring,
whose `ethernet_alloc_rx_frames()` reserves k slots for descriptors the ring
re-create then discards: reserved = 64 + k for the rest of the boot.  Before
the driver attaches the backlog is full of boot-time traffic, so k ~ 53 is
the expected size.  Per-boot because it needs a frame inside the window.
Independent of the read-ahead and of fastram/nofast.

Fix (drafted, not yet applied): hold `ethernet_pause_rx_irq()` across the
whole of `ethernet_restart_dma()` (Stop .. init_ethernet_buffers), as
`ethernet_receive_frame()` already does, resuming after the new ring is
armed.  Branch `fix/eth-restart-dma-irq-mask` off 6aeab1c in zz9k-clean.
Verify: flash upstream + fix (nofast), power-cycle until 20+ boots show
reserved = 64 and no slow state (base rate here: 2 slow of 12 upstream boots).

Second slow boot (ctl-14, 3.43 Mbit/s, RTT 203 ms): same signature, reserved
116-119 throughout.  Backpressure 0 for the first 66 samples (idle before the
iperf flow: pending = 0 + 119 < HIGH 120), then 1 from the first arrival to
the end, since pending can never fall to LOW 96.  Upstream tally so far:
slow 3 of 14 boots (4, 10, 14), all with reserved ~117; clean boots all 64.

Upstream nofast series complete (boots 1-20): **slow 3/20 (4, 10, 14)**.  The
two sampled slow boots (10, 14) both show reserved 116-119; all 16 sampled
clean boots (7-9, 11-13, 15-20 and 8) show reserved 64 and no backpressure.
Clean-boot RX 21.0-21.7 Mbit/s at 50 MHz, 25.4-26.1 at 82 MHz.

## Fix under test (2026-10-09 04:45Z)

`ethernet_restart_dma()` now holds `ethernet_pause_rx_irq()` from before
`XEmacPs_Stop()` until after `init_ethernet_buffers()` (branch
`fix/eth-restart-dma-irq-mask` in zz9k-clean, uncommitted).  Image:
`BOOT-upall-nofast-irqfix.bin` sha256 017882e1... = the same upstream nofast
bitstream as the control (da772ddb...) + ZZ9000OS.elf 83901f56... (control
elf e6d96168...).  Verification: 24 flushed power cycles with `zzrxs`;
pass = reserved 64 and no slow boot on every boot (control: 3/20 slow).

**Fix result so far (05:10Z): NOT a cure.**  irqfix boots 1-7 clean
(reserved 64, bp 0, 21.1-21.3 / 25.5-25.7 Mbit/s).  Boots 8 and 9 leaked again:
reserved 101-104 (~40 excess, vs ~53-55 before), bp 700/700, RX 21.3 / 22.9
Mbit/s with RTT 21-40 ms: degraded, not collapsed, because pending ~104 sits
between LOW 96 and HIGH 120 (backpressure never clears; PAUSE only when ready
>= 16).  Verified the masked path is in the elf (XScuGic_Disable -> Stop ->
clear -> init -> XScuGic_Enable).  All reset paths are main-loop
(handle_amiga_reset, main.c:702/704/2243) and go through restart_dma; GEM IRQ
stays on CPU0.  So restart_dma masking is at best partial: the leak has another
source.  Next: instrument (expose frames_backlog_reserved vs 64-FreeCnt and a
restart counter through a register) rather than guess.

## Packet receive window on hardware (2026-10-09 06:15Z)

Image: zz9k/packet-window-live fcc85f3 (FPGA packet core + mailbox + arbiter
in mntzorro.v, codex's ARM lease/mailbox producer 2e134d2 + 401a030), nofast,
TIMING_GATE PASS (setup +0.038 / hold +0.051 ns).  test/pw: 29/29 in xsim.

- Boot 1: RX stalled after ~120 frames (status ready 0, reserved 0); the
  ARM packet service had faulted.  Debug ELF (fault-site code + release
  count in RX_STATUS stats): fault reason 13 = ethernet_clear_host_state()
  called in packet mode without a completed fence, during bring-up.
- Boot 2 (debug ELF): reason 13 recorded but a later fence recovered; network
  fully up (DHCP + IPv6), 2485 frames, 0 bad/gaps/size drops.

| | upstream | read-ahead c8786cc | packet window fcc85f3 |
|---|---|---|---|
| RX Mbit/s, 50 MHz | 21.5-21.7 | 23.5-23.7 | 22.0 |
| RX Mbit/s, 82 MHz | 25.9-26.1 | 28.2-28.4 | 27.7 |
| window read ns/long @82 MHz | 584 (DDR) | 494 (line hit) | 505 (bank) |

The bank removes DDR latency, but a Zorro read through it costs about the
same as a read-ahead hit: the remaining ~500 ns is the Z3 front end.
Throughput sits between upstream and read-ahead; the ARM main-loop feed and
two banks are the likely limits (not yet measured).

## Root cause of the slow boots AND the packet-window dead boots (2026-10-09 07:20Z)

Both are the same upstream bug in `ethernet.c` (mntmn original code):
`XEmacPsRecvHandler()` called `XEmacPs_BdClearRxNew()` on every processed BD.
That clears the GEM used bit, i.e. hands the BD back to the GEM while it still
points at its old backlog slot and sits in the ring's *free* group.  And
`XEmacPs_BdRingFromHwRx()` was called with `BdLimit = RXBD_CNT`, not `HwCnt`
(the BSP walk only stops at the first BD without the used bit).

Normally the refill re-arms the same BDs at once, so the window is tiny.  At
boot the backlog fills to HIGH (120) before the driver opens, refills stop,
and the GEM keeps DMAing into "free" BDs over queued slots; the Xilinx ring's
HwHead/HwCnt drift away from the GEM's queue pointer.  Legacy mode: leaked
reservations (reserved ~117, PAUSE latched, 3.4 Mbit/s).  Packet mode: the
lease checks trip (fault 5 / 0x52) and RX dies.

Evidence: dbg4 first-fault snapshot of a dead boot (raw files in
`~/ooc-evidence/pw-deadrx/`): reason 0x52 at BD16, GEM RXQ pointer = BD16
(= 144 frames written), Xilinx HwHead 56 / HwCnt 24, BDs 16-55 in the free
group yet posted (used=0) with live slots.  Unfixed: 9 of 19 boots dead.

Fix (tinic fork `zz9k/rx-bd-ownership-wip` 9a790af, ordering per codex):
RX BD template starts with the used bit set; it stays set through completion
and preparation; it is cleared only after a successful `BdRingToHw()` with a
DSB; `FromHwRx` is bounded to `HwCnt`.  Host regression (codex, 6ebc09c):
actual firmware RX functions + actual BSP ring routines, 6 cases, packet and
legacy mode, gcc and clang-19: all pass on the fix, all fail on 910970b.

Hardware: fix + debug counters, 8/8 boots good (fault 0,
22.05-22.33 / 27.57-27.76 Mbit/s at 50 / 82 MHz).

Clean fix image (9a790af, no instrumentation; BOOT 92f49b9e..., ELF 477ec57f...):
**8/8 boots carry RX**, 22.03-22.27 / 27.55-27.79 Mbit/s at 50 / 82 MHz,
backpressure 0 in every sample.  Integrated on zz9k/packet-window-live as
e19c45b (fix + codex's rx_bd and rx_init host regressions), pushed to the
tinic fork.  The same fix applies to legacy (non-packet) firmware: it should
also end the upstream slow-boot reserved leak (not yet measured on a legacy image).

**Correction (2026-10-09, caught by codex):** the packet-window "window read
ns/long" figures (505 ns @82 MHz in the table above, and the ~578/600 ns in
the packet-window boot logs) come from `z3read ADDR=48002000 SIZE=16384`,
which spans 0x2000-0x5fff.  The packet bank only covers 0x2000-0x27ff, so
those numbers mix one 2 KB bank read with 14 KB of plain DDR reads; they are
NOT active-bank latency.  A bank-only measurement needs SIZE=2048 with a
packet held in the bank.  The RX Mbit/s figures are unaffected.

## Read-ahead + ownership fixes on hardware (789e9b1, 2026-10-09 09:43-10:07Z)

Image `BOOT-rxpf-789e9b1-nofast.bin` b6e31172... = c8786cc read-ahead
bitstream (unchanged) + ARM with the RX BD ownership fix, guarded
restart_dma, hw_ready gate and MAC-update clear.  Eight flushed power
cycles, `pwmeasure.sh` as before.

| | 50 MHz RX Mbit/s | 82 MHz RX Mbit/s | window readl ns (50/82) | dead/degraded |
|---|---|---|---|---|
| upstream nofast (control, earlier) | 21.0-21.7 | 25.4-26.1 | 574 | 3/20 slow |
| read-ahead c8786cc, old ARM | 23.5-23.7 | 28.2-28.4 (one 24.6) | 452 | 1/6 degraded |
| **read-ahead 789e9b1, fixed ARM** | **23.06-23.18** | **27.81-27.89** | 452 / 494 | **0/8** |

All 8 boots: backpressure 0 in every sample.  Versus upstream: +7 % at both
clocks.  Versus the old-ARM read-ahead: ~2 % lower at 50 MHz and ~1.5 % at
82 MHz but no outliers.  Not yet attributed: the ownership fix hands each
refilled BD to the GEM with a DSB after BdRingToHw (one barrier per BD); that
per-frame ARM cost is the first suspect, untested.

## Read-ahead + RX ownership fixes on hardware (2026-10-09 09:43-10:15Z)

Image `BOOT-rxpf-789e9b1-nofast.bin` (b6e31172..., ELF 6f76cd28..., bit
d371600e... unchanged c8786cc read-ahead).  8 flushed power cycles, 50 MHz
then `cpuspeed 86` from the shell (82 MHz):

| | RX 50 MHz | RX 82 MHz | window readl 50/82 | bad boots |
|---|---|---|---|---|
| 789e9b1 (8 boots) | 23.06-23.18 | 27.81-27.89 | 452 / 494 ns | 0 |
| c8786cc old ARM (6 boots) | 23.5-23.7 | 28.2-28.4 (one 24.6) | 452 ns | 1 |

All 8 boots carry RX, backpressure 0 in every sample.  The fixed build is
~1.5-2 % below the c8786cc numbers taken on 10-09 01:xx; NOT attributed:
the per-refill DSB/handoff, or run-to-run conditions.  Needs a same-session
A/B (c8786cc vs 789e9b1, interleaved) before claiming either way.
Logs: ~/ooc-evidence/rxpf-bdfix/.

## Read-ahead + RX ownership fixes on hardware (2026-10-09 09:43-10:07Z)

Image `BOOT-rxpf-789e9b1-nofast.bin` sha256 b6e31172... = read-ahead bitstream
rxpf4-nofast.bit (d371600e..., unchanged c8786cc RTL) + ARM 789e9b1 (RX BD
ownership, restart IRQ mask, hw_ready gate, MAC-update clear deferred).
8 flushed power cycles: **8/8 boots carry RX, no dead or slow boot**,
backpressure 0 in every sample.

| | RX Mbit/s 50 MHz | RX Mbit/s 82 MHz | window readl ns (50 / 82) |
|---|---|---|---|
| read-ahead + fixes 789e9b1 (8 boots) | 23.06-23.18 | 27.81-27.89 | 452 / 494 |
| read-ahead unfixed c8786cc (6 boots) | 23.5-23.7 | 28.2-28.4 (1 boot 24.6) | 452 / - |

The fixed image is ~1.5 % below the unfixed read-ahead in RX.  Not resolved:
per-BD handoff after ToHw + DSB in the refill path, or day-to-day variance
(not an interleaved A/B).  Logs: ~/ooc-evidence/rxpf-bdfix/.

## Read-ahead + RX ownership fixes on hardware (2026-10-09 09:43-10:15Z)

Image `BOOT-rxpf-789e9b1-nofast.bin` (b6e31172...; ELF 6f76cd28..., bit
d371600e... unchanged c8786cc read-ahead).  Eight flushed power cycles,
50 MHz then `cpuspeed 86` from the shell (82 MHz).  **8/8 boots carry RX, no
degraded run, backpressure 0 in every sample.**

| | RX 50 MHz | RX 82 MHz | window readl ns 50/82 |
|---|---|---|---|
| read-ahead + fixes 789e9b1 (8 boots) | 23.06-23.18 | 27.81-27.89 | 452 / 494 |
| read-ahead c8786cc, old ARM (6 boots) | 23.5-23.7 | 28.2-28.4 (1/6 degraded 24.6) | 452 |
| packet window + fix e19c45b (8 boots) | 22.0-22.3 | 27.5-27.8 | n/a (bank+DDR mix) |

The fixed build is ~1.5-2 % below the old read-ahead runs with identical bus
timing; not attributed (candidate: per-BD ToHw + DSB + NEW clear on refill,
or run-to-run peer variance).  Evidence `~/ooc-evidence/rxpf-bdfix/`.

## Z3 copy cost (z3copy, 2026-10-09, 789e9b1 image, TF4060 at 82 MHz)

`z3copy` (source in `~/ooc-evidence/rxpf-bdfix/z3copy.c`): 1512-byte copies
into Fast RAM, best of 5 x 64, bytes and guard regions verified (0 errors).

| source | movem dst+0 | movem dst+2 | move.l dst+0/+2 | move16 dst+0 |
|---|---|---|---|---|
| RX window $48002000 (read-ahead) | 195.3 us, 517 ns/long | 201.5 us | 205.0 us | 192.4 us |
| card DDR $4C000000 | 227.6 us, 602 ns/long | 236.4 us | 242.7 us | 229.2 us |
| Fast RAM (cache-resident control) | 10.2 us | 19.3 us | 9.9 / 18.9 us | 38.0 us |

- The Z3 read cycle dominates: method choice moves the copy by <=5 %, dst+2
  by ~3 %, MOVE16 by ~1.5 % (no Z3 burst).  The driver's MOVEM loop is already
  the best general form; no copy-loop change is justified.
- Read-ahead saves ~14 % per longword (517 vs 602 ns).
- At 27.8 Mbit/s (~2300 frames/s) the copy alone is ~46 % of CPU time.
- Remaining lever without bus mastering: card response latency, 517 ns per
  access vs the ~296 ns Buster floor quoted for Z3, i.e. up to ~1.7x on the
  copy if the ZZ9000 front end could answer a read-ahead hit faster.

## Zorro III copy cost (z3copy, 789e9b1 image, 2026-10-09 ~10:10Z)

`test/rxpf/z3copy.c`: one 1512-byte frame copied into Fast RAM, best of 5
x 64 copies, E-clock under Forbid, bytes and guard regions verified (all 0
mismatches).  movem = the driver's n68k_copy_longs loop; movel = unrolled;
move16 only with both ends 16-byte aligned.  Same boot, `cpuspeed 86` then
`cpuspeed 50` from the shell.

| us per frame | 82 MHz movem +0 | +2 | movel +0 | +2 | move16 | 50 MHz movem +0 | +2 | movel +0 | +2 | move16 |
|---|---|---|---|---|---|---|---|---|---|---|
| RX window (read-ahead) | 192.9 | 201.4 | 205.4 | 205.1 | 193.0 | 184.9 | 197.8 | 186.4 | 201.9 | 184.7 |
| card DDR (no read-ahead) | 230.4 | 239.3 | 242.5 | 242.4 | 229.6 | 228.7 | 242.8 | 234.6 | 248.8 | 226.1 |
| Fast RAM control | 10.2 | 19.3 | 9.9 | 18.9 | 38.0 | 16.9 | 31.9 | 16.3 | 31.3 | 59.0 |

Readings:
- The card copy is bus-bound, not CPU-bound: 82 MHz is slightly *slower*
  than 50 MHz (~490 vs ~510 ns/long), consistent with the window readl
  452 -> 494 ns seen in every boot.  The CPU-clock gain in RX (23.1 -> 27.9
  Mbit/s) comes from the non-copy work.
- Read-ahead saves ~16-19 % per frame over plain DDR (185 vs 229 us @50).
- move16 = movem (no Z3 burst); movel is 1-6 % slower; the driver's movem
  loop is already the right choice.
- dst+2 (IP-header alignment) costs 8.5-13 us per frame (4-7 % of the copy).
- Budget at the measured RX rates: the copy is 35 % (50 MHz, 185 of 524 us
  per frame) and 44 % (82 MHz, 193 of 435 us) of the per-frame time.  If a
  Z3 read cost the ~296 ns Buster floor instead of ~490-510 ns, the copy
  would be ~112 us and RX would model at ~26.9 / ~34.2 Mbit/s (+16 / +23 %).
  So the next target is the ZZ9000's Z3 slave response latency (the ~200 ns
  per longword above the floor), not the 68k copy loop.
- Smaller, cheap target: place the frame so window source and RAM
  destination share alignment (payload at offset 2 mod 4 in the slot, one
  word peeled), removing the dst+2 penalty: ~2-2.5 % of frame time.

**Correction to the "next target" above (same day):** the FPGA is not where
the ~490 ns per longword goes.  `rxpf_tb.v` now reports the read-ahead hit
latency: /FCS falling -> /DTACK asserted = **60 ns** (6 clocks at 100 MHz:
FCS synchroniser, address decode, Z3_IDLE, WAIT_READ_DMA_Z3, Z3_RXPF_SERVE),
and /DTACK follows the data strobes by 10 ns in the testbench's strobe
timing.  So of ~452-494 ns measured per window longword on the TF4060, only
~60 ns is the ZZ9000's response; the rest is the TF4060 -> A3000 bus path
(Buster cycle and the accelerator's bus bridge, which also explains why the
copy gets slower at 82 MHz).  Speeding up mntzorro.v's read FSM can save at
most a few tens of ns per longword.  Remaining levers:
- the non-copy work per frame (339 us @50 MHz, 242 us @82 MHz: driver, stack,
  TCP, ACK transmit) -- the larger share of frame time;
- fewer Z3 cycles per frame (no burst on this bus path: move16 = movem);
- the dst+2 alignment penalty (8.5-13 us per frame);
- moving the copy off the 68060 entirely (ZZ9000 bus mastering into
  motherboard RAM; unknown cost of the 060 reading motherboard RAM back --
  measure before considering).

## RX offset 2 (dst+2 removed), A/B on hardware (2026-10-09 10:27-10:55Z)

Firmware `zz9k/rx-offset2` 2156a56 (BOOT 5659ba94...): opt-in GEM RX buffer
offset 2 (ETH_CONFIG 0x1000|1, length bit 15, RX_META bit 12, off on Amiga
reset).  Same firmware in both arms; only the driver differs:
A = anxzz9000.device from AmiNetXDuo origin/main 8bb3dc44 (never asks),
B = AmiNetXDuo `fix/zz9000-rx-offset2` 6c28957a (asks; payload copy aligned
on both sides).  ABBA ABBA, 8 flushed power cycles, size-checked install.

| arm | 50 MHz RX Mbit/s | median | 82 MHz RX Mbit/s | median |
|---|---|---|---|---|
| A main | 23.10 23.19 23.21 23.21 | 23.20 | 27.81 27.94 27.96 27.99 | 27.95 |
| B offset2 | 23.63 23.64 23.67 23.80 | 23.66 | 28.17 28.20 28.20 28.35 | 28.20 |

B beats A in every pair, ranges disjoint: **+2.0 % at 50 MHz, +0.9 % at 82
MHz**, as predicted from z3copy's dst+2 cost (12.9 / 8.5 us per frame).
Backpressure 0 throughout.  Evidence: ~/ooc-evidence/rxoff2/.

## RX offset 2 (dst+2 removed): A/B on hardware (2026-10-09 10:27-10:55Z)

Firmware zz9k/rx-offset2 2156a56 (`BOOT-rxpf-2156a56-nofast.bin` 5659ba94...,
read-ahead bitstream unchanged): opt-in GEM RX buffer offset 2 via
REG_ZZ_ETH_CONFIG 0x1000|1, length bit 15 on shifted frames, RX_META bit 12,
off on every Amiga reset.  Driver AmiNetXDuo fix/zz9000-rx-offset2 6c28957a
asks for it when offered; copies peel a word only when the source is 2 mod 4.
Same firmware in both arms; A = origin/main 8bb3dc44 anxzz9000.device (never
asks), B = the branch.  ABBA ABBA, flushed power cycles, install size checked.

| RX Mbit/s | A (4 boots) | B (4 boots) | B vs A |
|---|---|---|---|
| 50 MHz | 23.10-23.21, median 23.20 | 23.63-23.80, median 23.66 | +2.0 % |
| 82 MHz | 27.81-27.99, median 27.95 | 28.17-28.35, median 28.20 | +0.9 % |

No overlap between the arms at either clock; backpressure 0 throughout.
Predicted from z3copy: dst+2 costs 8.5-13 us of ~435-524 us per frame
(2-2.5 %).  Evidence: ~/ooc-evidence/rxoff2/.

## RX offset 2: the dst+2 penalty removed (2026-10-09 10:27-10:55Z)

Firmware zz9k/rx-offset2 2156a56 (opt-in GEM RX buffer offset 2 via
REG_ZZ_ETH_CONFIG 0x1000|1, length bit 15 marks shifted frames, RX_META bit
12 advertises it, cleared on Amiga reset), image BOOT-rxpf-2156a56-nofast.bin
5659ba94... (read-ahead bitstream unchanged).  Driver: AmiNetXDuo
fix/zz9000-rx-offset2 6c28957a (asks for the layout when offered; the copies
peel a word only when the source is 2 mod 4).  Same firmware in both arms;
A = origin/main 8bb3dc44 anxzz9000.device (never asks), B = 6c28957a.
Eight flushed power cycles, ABBA ABBA, driver size verified before each cycle.

| Mbit/s | A (main) | B (offset 2) | median B vs A |
|---|---|---|---|
| 50 MHz | 23.10, 23.21, 23.21, 23.19 | 23.80, 23.67, 23.64, 23.63 | **+2.0 %** |
| 82 MHz | 27.81, 27.94, 27.99, 27.96 | 28.35, 28.20, 28.17, 28.20 | **+0.9 %** |

Every B leg beat every A leg at both clocks; backpressure 0 in all 11200
samples.  Size matches the z3copy estimate (the 8.5-13 us per frame the +2
destination cost).  Read-ahead + offset 2 at 50 MHz (23.6-23.8) now matches
the old unfixed read-ahead peak (23.5-23.7) with the ownership fixes kept.
