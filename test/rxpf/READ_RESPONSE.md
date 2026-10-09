# RX-window pin response experiment

This candidate stages an already received read-ahead beat in `Z3_IDLE`, then
acknowledges in a separate state. A miss also uses that acknowledgment state,
allowing the existing output-pipeline register to receive the word before ACK.
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

The response test requires no late data, early ACK, repeated ACK or wrong data.
Against the original RTL, `run_response.sh baseline` records the expected
negative control. It does not waive the candidate's acceptance criteria.

The original early/typical-strobe hit responds in 51–60 ns after /FCS, but
its actual FPGA data pins become valid 10 ns later. The candidate responds
in 41–50 ns with early strobes, or at 50 ns when the strobes arrive then.
With late strobes it responds at the data phase rather than prematurely.
The miss path adds one 10 ns clock for the output pipeline. These are digital
simulation measurements, not bus throughput results.

The Zorro III timing addendum specifies a minimum 0 ns read-data setup to
/DTACK, with DOE 30–100 ns after /FCS and strobes 10–30 ns after DOE:
https://www.devili.iki.fi/mirrors/haynie/zorroiii/docs/z3_add.pdf (section 3).
The candidate has zero digital setup margin in some phases. Before any image is
called ready, measure FPGA memory inference, resources, routed setup/hold and
output data-versus-ACK delays, including level-shifter/transistor effects.
General internal timing closure does not establish this asynchronous I/O margin.
The known-good nofast BOOT b6e31172 remains the hardware comparison baseline.

The roughly 450–500 ns CPU-visible read time is not 200 ns of removable FPGA
delay: this experiment targets at most one hit-response clock. The realized
gain depends on Buster/TF4060 sampling and must be measured with the same ARM
image, driver, CPU speed and read-ahead variant before drawing conclusions.
