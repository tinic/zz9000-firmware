# Standalone packet-bank synthesis and timing probe

Run `run_ooc.py` in a firmware checkout containing its committed inputs. It
synthesizes **only** `zz_eth_packet_window`, then places and routes that isolated
module. It does not call `build_bitstream.sh`, generate an image, or include the
shared arbiter, ARM transport, Zorro adapter or other FPGA clients.

The target is `xc7z020clg400-1`, matching `zz9000_project.tcl`. The primary clock
is **100 MHz (10 ns)**: the project connects m00/MNTZorro to FCLK0. zz9k-fpga
confirmed on 2026-10-08 that ARM does not reprogram that clock. Its earlier
6.7 ns-per-arbiter-clock estimate was incorrect. The full-design 150 MHz runtime
constraint describes the DVI pixel clock, not m00; the optional 150 MHz probe
is a margin experiment only.

## Run on the reserved Vivado lane

Source the normal Vivado 2018.3 environment, then run one job at a time:

```sh
nice -n 10 python3 test/eth_packet_window/run_ooc.py \
  --period-ns 10.0 --output build/packet-ooc-100
```

An optional, separate run may use `--period-ns 6.666667` with a new output
directory. Do not run both in parallel on the shared machine. The script sets
Vivado's maximum thread count to one. Use `--vivado /absolute/path/to/vivado`
when the environment does not put it on PATH.

Existing output directories are rejected. The runner verifies the HDL and both
runner files against the current Git commit, records their SHA-256 hashes, and
copies that exact content into a temporary source snapshot. Unrelated checkout
edits are not synthesis inputs. Vivado runs inside task-local scratch, which the
runner removes on completion or failure; reports and logs remain in the output
directory for review. It saves no checkpoints or bitstreams.

## Boundary assumptions and report interpretation

The generated `boundary.xdc` is part of the evidence. All data/control inputs,
including synchronous reset, have 1 ns maximum and 0 ns minimum input delay.
All outputs have the same assumed delay budget. Clock uncertainty is 0.1 ns
for setup and 0.05 ns for hold. There are no false-path or multicycle exceptions.
These are explicit synchronous interface assumptions, **not measured Zorro/ACP
timing constraints**. There are no package I/O buffers/pin assignments in this
out-of-context module. Whole-design placement, clock routing, contention and
actual boundary paths remain to be tested after integration.

Retain and inspect:

* `manifest.json`: source identity, input/report hashes, clock/boundary assumptions,
  invoked command, process status and the fixed `image_ready: false` marker.
* `memory_cells.tsv` and `inference.tsv`: inferred RAMB18E1/RAMB36E1 counts, cell
  names and port widths. The intended payload storage is two 512 x 32-bit banks.
  A capacity count alone does not prove correct inference: check names/widths,
  synthesis messages and utilization for unexpected distributed RAM/registers.
* `synth_utilization.rpt`, `routed_utilization.rpt`: actual isolated resource use.
* `synth_timing.rpt`, `routed_timing.rpt`, `clocks.rpt`, `check_timing.rpt`:
  setup/hold paths, boundary coverage and unconstrained-path diagnostics.
* `routed_hold_paths.rpt`, `routed_setup_paths.rpt`, `internal_hold_paths.rpt`,
  `input_hold_paths.rpt`: expanded clock/data path detail, with separate internal
  register-to-register and input-to-register hold paths. This distinguishes a
  real internal violation from assumed interface timing; neither is waived.
* `route_status.rpt`, `drc.rpt`, `console.log`, `vivado.log`: routing completion,
  DRC findings and tool warnings/errors. Review these even after process success.

The numeric gate requires a clock, both finite timing paths, nonnegative setup
and hold slack, and at least two RAMB18 equivalents. It preserves available
reports and returns failure when a check fails. A zero exit status means only
that these numeric checks passed: constraint coverage, memory structure, DRC and
route status still require review. It is never an image-ready or performance gate.
Unexpected RAM use or a negative slack result is evidence to investigate, not a
reason to weaken the constraints or remove checks.

The existing c8786cc nofast reports supplied by zz9k-fpga show 3,853 LUTs, 5,410
FFs and 4/140 BRAM tiles in MNTZorro OOC synthesis, with full-design setup/hold
slack +0.000/+0.015 ns. Those are **baseline** measurements. They do not include
these packet banks and cannot be added arithmetically to predict routed timing.

## Measured 100 MHz result, 2026-10-08

zz9k-fpga ran Vivado 2018.3 on playhouse2 at exact commit
`1c6384c7aa343ee8c4c0fd3070e69c4fbefda6e4`. Its detailed-path follow-up kept the
RTL and generated constraints identical to the first completed `777cc71` run.
The source and report hashes were checked independently after retrieval.

| Measurement | Isolated core result |
| --- | --- |
| Memory | 2 RAMB18E1, 0 RAMB36, 0 LUTRAM |
| Logic | 293 LUTs, 254 FFs |
| Setup slack | +1.490 ns |
| Internal register-to-register hold slack | +0.063 ns |
| Input-to-register hold slack | -0.552 ns |
| Overall numeric gate | **FAIL**, exit 1; constraints unchanged |

`ram0_reg` and `ram1_reg` infer as 36-bit simple-dual-port RAMB18E1 primitives
for the two 512 x 32-bit banks. The worst setup path reaches BRAM write enable
from `fill_bank_reg`. The worst input hold path is `desc_cookie[12]` to
`cookie_reg[0][12]/D`: 0 ns assumed input delay, 0.924 ns data delay, 0.973 ns
destination clock delay and a 1.476 ns total required time yield -0.552 ns slack.
The worst internal hold path is a cookie register to its release-cookie register;
the next reported path into a RAM write address passes at +0.076 ns.

There are no missing-clock/delay or unconstrained-internal-endpoint findings in
`check_timing`; 438 nets route fully with zero routing errors. DRC reports only
the absent PS7 block, expected for this isolated core. However, Vivado warns
that **HD.CLK_SRC and HD.PARTPIN_LOCS are absent**: the clock source and external
boundary partial routes have no full-design physical context. Thus the input
failure identifies an unresolved interface assumption, not a proven internal
logic defect or a proven harmless hardware path. Internal slack also remains
conditional on the OOC context. Preserve the failure; do not waive it or infer
full-design timing closure from these numbers.

The next timing step needs the actual registered descriptor producer/transport
and shared clock context, followed by full-design implementation. No 150 MHz
probe, new FPGA image, hardware run or throughput measurement was made here.

Vivado reference: [UG835 timing-path queries](https://docs.amd.com/r/2020.2-English/ug835-vivado-tcl-commands/get_timing_paths)
describe querying slack from path objects; the lane's actual Vivado 2018.3 run
must establish command compatibility and the measured result. Local syntax or
mock-command checks are only runner checks, never synthesis evidence.

## Combined engine profile

`--top engine` selects `zz_eth_packet_engine`: AXI-Lite adapter, registered mailbox,
packet core and shared read arbiter, with the wrapper defaults (one-bit AXI IDs,
packet ARCACHE 0xf). The default `--top core` retains the original isolated core
profile. The runner hashes every selected RTL input, records the selected top,
and uses the same clock and interface budgets for both. No constraints are
relaxed to remove an input hold failure.

```sh
python3 test/eth_packet_window/run_ooc.py --top engine --period-ns 10.0 \
  --output build/packet-engine-ooc
```

The engine adds `descriptor_setup_paths.rpt` and `descriptor_hold_paths.rpt`
for mailbox `desc_cookie` registers to core cookie registers. Missing cells or
paths fail the run instead of allowing an optimized-away producer to count as
validation. These paths distinguish the now-internal descriptor transfer from
the remaining external interface budgets. Core-only measurements above do not
measure this combined design; actual engine reports must be reviewed separately.
The combined probe still lacks the live block-design/PS clock and physical port
context, Zorro adapter and real reset controller. Even an OOC numeric pass is
not image readiness, full-design closure or a throughput result.
