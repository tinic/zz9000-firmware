# RX-window pin response experiment

This candidate stages an already received read-ahead beat in `Z3_IDLE`, enables
the output, waits through `Z3_RXPF_GUARD` for the output-pipeline register to load,
then acknowledges on the following edge. A miss uses the same sequence after
`Z3_RXPF_SERVE`. Data has a full clock of digital setup before ACK; output enable
is requested two clocks before ACK. Invalidated lines withdraw output enable
and retry; logical reset clears output enable and enters RESET.
The AXI request/response ownership machinery and control synchronizers are
unchanged. The additional lookup path needs routed timing review.

RX-window ACK is qualified combinationally by the master's data strobes as well
as DOE. This qualifies an asynchronous output handshake; it does not bypass the
input synchronizers used by the state machine. The timeout starts only after
the synchronized data strobes arrive and saturates instead of wrapping. This
prevents a precomputed response from expiring before a late data phase, or
reappearing 256 clocks later while /FCS remains active. Other read/write paths
keep their existing behavior.

The original fixture sampled pre-output-pipeline registers 20 ns after ACK.
It now samples the IOBUF pins, preserves the 30 us timeout after the earlier
change to 1 ns polling, and exposes timing controls for a separate response
test. That test uses actual RTL plus the existing AXI model, sweeping all ten
100 MHz clock phases, DOE delays of 30/40/100 ns and data-strobe delays of
10/30 ns. It tests real cache misses/hits and holds one completed cycle for
4 us to detect timeout wraparound. The nofast variant is applied only to the
simulation copy. Autoconfig is still seeded; analog board delays are not modeled.

With the Vivado 2018.3 environment sourced and VIVADO_DIR set:

```sh
bash test/rxpf/run_response.sh
bash test/rxpf/run.sh
```

The response test requires no late data, early ACK, repeated ACK or wrong data,
and at least 10 ns of digital data and direction/enable setup on every read.
Against the original RTL, `run_response.sh baseline` records the expected
negative control. `run_response.sh unguarded` checks the expected setup-margin
failure of the earlier 0551318 candidate with this stronger fixture. Neither
control mode waives the candidate's acceptance criteria.

The original early/typical-strobe hit responds in 50–59 ns after /FCS, but
its actual FPGA data pins become valid 10 ns later. The guarded candidate is
measured in simulation to respond in 50–59 ns for early/typical strobes; late strobes still
qualify ACK at the data phase. The miss path now adds two 10 ns clocks relative
to the original ACK. The 122 checks measured at least 10 ns of data setup and 10 ns of enable setup.
Two additional guard-state tests invalidate via fabric reset or registered slot
change; both withdraw output enable and retry exactly once with correct data.
These are digital simulation measurements, not bus throughput results.

The earlier 0551318 prototype reduced hit ACK latency by 10 ns but launched
latched data and ACK together. Independent exact routed checkpoint 79b8a93d...
(bit a3a1bd5d...) analysis found conservative same-corner FPGA bounds:
ACK minus latest data -1.422/-1.120 ns and ACK minus latest output enable
-4.032/-2.008 ns at Slow/Fast. These include clock-network propagation and
positive ACK assertion. They exclude external shifters/transistor/PCB effects
and are not observed board errors. They invalidate a setup sign-off based on
zero-delay simulation or comparing only maximum ACK delay. Both the IDLE hit
and SERVE paths need the guard; the earlier claim of one clock of data lead on
IDLE hits was incorrect.

The Zorro III timing addendum specifies a minimum 0 ns read-data setup to
/DTACK, with DOE 30–100 ns after /FCS and strobes 10–30 ns after DOE:
https://www.devili.iki.fi/mirrors/haynie/zorroiii/docs/z3_add.pdf (section 3).
The guard provides digital margin, but it changes the implementation. Before
any corrected image is called ready, remeasure FPGA memory inference, resources,
routed setup/hold and
output data-versus-ACK delays, including level-shifter/transistor effects.
General internal timing closure does not establish this asynchronous I/O margin.
The known-good nofast BOOT b6e31172 remains the hardware comparison baseline.

The roughly 450–500 ns CPU-visible read time is not 200 ns of removable FPGA
delay. The guard removes the proposed one-clock hit-response saving. Any later
optimization must preserve measured physical setup; its realized gain depends
on Buster/TF4060 sampling and must be measured with the same ARM
image, driver, CPU speed and read-ahead variant before drawing conclusions.
