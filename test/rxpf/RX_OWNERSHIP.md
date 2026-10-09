# GEM descriptor ownership on the read-ahead branch

The read-ahead FPGA still uses the legacy ARM receive path. This test runs the
actual functions from that branch, not the packet producer selected into legacy
mode. The ownership fix is a backport of production commit `9a790af`:

- Start RX descriptors with NEW set (software owns them).
- Keep NEW during completion and preparation, including a backpressure stop.
- Assign the new address/reservation, submit successfully with `BdRingToHw`,
  execute DSB, then clear NEW to grant DMA ownership. Rejection grants nothing.
- Limit `BdRingFromHwRx` to the ring's hardware-owned work count (`HwCnt`).

Run from the repository root:

```sh
python3 test/rxpf/run_rx_bd.py
python3 test/rxpf/run_rx_init.py
```

Both use Clang, C99, `-Wall -Wextra -Werror -pedantic`, ASan and UBSan. `--cc`
selects another compiler. The fixture is derived from the reviewed runtime and
initialization fixtures integrated in packet-window commit `e19c45b`, with all
packet-only state and cases removed; no packet headers or code are required.

Six runtime groups cover retained ownership under pressure, bounded completion
scan, address/reservation/ring/barrier before handoff, failed ToHw rollback, a
120-frame stop at BD56 followed by refill, and 64+56 completion batches. The
fixture now observes the barrier at each watched runtime ownership handoff.
Eight init groups execute actual init/prepare/clear plus bundled BSP ring
Create/Clone/Alloc/UnAlloc/ToHw, with success and failures at each setup stage.
Partial preparation fails at positions 0, 7 and 63. The legacy caller initializes
host accounting before ring creation; the fixture makes that precondition
explicit rather than importing packet fence/rearm behavior.

The unchanged baseline `c8786cc` fails all six runtime cases and the init-success
case at ownership assertions. Removing either the initial or runtime handoff
barrier independently makes its corresponding test fail. These negative controls
are validation evidence, not expected failures to suppress.

Host adaptations: pointer-sized ring indexing; synthetic 32-bit payload addresses;
explicit `(void)` prototypes; the descriptor length local is unsigned after the
actual 13-bit BSP mask; an explicit void-use of Create's unused `BdPhyAddr` local
retains Werror. No warning flag is disabled. Hardware/MMIO/cache operations are
boundary stubs. A DSB call is observed, but physical cache/DMA ordering, pending
GIC interrupts, AXI behavior and boot stability need separate validation.

The FPGA RTL is unchanged. Use the retained **zorro3-nofast** bitstream and verify
its hash/variant when building the combined image. Passing these tests is not a
hardware or throughput claim.

## Restart prerequisite

The legacy `ethernet_restart_dma` originally cleared accounting and recreated
rings with the GEM GIC line enabled. `XEmacPs_Stop` does not mask a pending CPU
interrupt. The packet branch already excludes that handler throughout restart;
carry the same guard into the legacy path, restore the IRQ on both exits, and
keep `ethernet_hw_ready` false unless reinitialization succeeds.

```sh
python3 test/rxpf/run_rx_restart.py
```

Three groups run the actual restart body against explicit GEM/GIC/init stubs:
success, init failure and absent register base. They check exclusion before Stop,
status clearing and ring reconstruction, readiness publication, and IRQ restoration.
The unguarded baseline, a missing failure-path resume, and stale-ready mutation
all fail runtime assertions. This fixture models a READY caller with GEM IRQ
initially enabled; it does not simulate interrupt dispatch or physical DMA drain.

The MAC-update caller formerly cleared host accounting before entering restart.
Remove that redundant clear as well: old-ring interrupts may still arrive before
the critical section, so the old ring must retain its matching accounting until
restart masks the IRQ and clears/rebuilds both together. MAC programming still
occurs with GEM stopped; the guarded restart performs the one accounting clear.
`python3 test/rxpf/run_rx_mac_restart.py` checks the actual caller for successful
programming, programming failure and the inactive no-op path. The restart-only
parent fails the explicit unguarded-clear assertion. Its restart and hardware
boundaries are stubs, not a physical interrupt/DMA model.
