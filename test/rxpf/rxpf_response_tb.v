`timescale 1ns/1ps
// Actual mntzorro + existing AXI fixture, checking the IOBUF pins rather than
// the pre-output-pipeline registers. This models digital timing only.
module rxpf_response_tb;
  rxpf_tb #(.EXTERNAL_DRIVER(1)) tb();
  reg active = 0;
  reg [31:0] expected;
  wire [31:0] pins = {tb.ZORRO_DATA, tb.ZORRO_ADDR[22:7]};
  realtime tfcs, tack, tdata;
  integer checked = 0, late = 0, wrong = 0, repeats = 0, early = 0, ack_edges = 0, phase, delay_sel, k, ns;
  reg [31:0] got;

  always @(negedge tb.ZORRO_NFCS) if (active) tfcs = $realtime;
  always @(pins) if (active && pins === expected && tdata < 0)
    tdata = $realtime;
  always @(posedge tb.ZORRO_NDTACK) if (active) begin
    if (ack_edges == 0) tack = $realtime;
    else repeats = repeats + 1;
    ack_edges = ack_edges + 1;
    if (tb.ZORRO_NUDS && tb.ZORRO_NLDS && tb.ZORRO_NDS1 && tb.ZORRO_NDS0)
      early = early + 1;
    #0.001;
    if (pins !== expected) late = late + 1;
  end

  task read_word(input [31:0] off);
    integer before_ar;
    begin
      expected = tb.swapped(tb.model(tb.ddr(off, 3), tb.gen));
      tdata = -1; tack = -1; tfcs = -1; ack_edges = 0;
      before_ar = tb.ar_count;
      active = 1;
      tb.z3cycle(tb.BOARD + off, 1, 2'b11, got, ns);
      active = 0;
      checked = checked + 1;
      if (got !== expected || tdata < 0 || tack < 0 || tb.hung != 0)
        wrong = wrong + 1;
      $display("RESPONSE phase=%0d doe=%0d ds=%0d off=%h ar=%0d fcs_ack=%0.3f fcs_data=%0.3f setup=%0.3f ns",
        phase, tb.fcs_doe_ns, tb.doe_ds_ns, off, tb.ar_count-before_ar,
        tack-tfcs, tdata-tfcs, tack-tdata);
    end
  endtask

  initial begin
    $timeformat(-9, 3, " ns", 8);
    repeat (20) @(posedge tb.clk);
    tb.dut.z3_ram_low = tb.BOARD;
    tb.dut.z3_confdone = 1;
    tb.dut.slv_reg4 = 3;
    tb.dut.zorro_state = 9;
    repeat (4) @(posedge tb.clk);
    tb.dut.zorro_state = 12;
    repeat (10) @(posedge tb.clk);
    // Sweep every ACLK phase and early/typical/late legal DOE. Keep the
    // full input synchronizers; no injected cache contents or DUT hit force.
    for (delay_sel = 0; delay_sel < 3; delay_sel = delay_sel + 1) begin
      tb.fcs_doe_ns = delay_sel == 0 ? 30 : delay_sel == 1 ? 40 : 100;
      tb.doe_ds_ns = delay_sel == 2 ? 30 : 10;
      for (phase = 0; phase < 10; phase = phase + 1) begin
        @(negedge tb.clk); #(phase);
        read_word(32'h2000); // backwards/header poll: a real DDR miss
        for (k = 1; k < 4; k = k + 1) begin
          @(negedge tb.clk); #(phase);
          read_word(32'h2000 + k*4);
        end
      end
    end
    // Keep /FCS and data strobes active beyond the old eight-bit timeout
    // wrap. A slave may withdraw its ACK but must not emit a second one.
    tb.fcs_doe_ns = 40; tb.doe_ds_ns = 10;
    read_word(32'h2200);
    tb.post_ack_hold_ns = 4000;
    read_word(32'h2204);
    $display("RESPONSE checked=%0d late_at_ack=%0d early_ack=%0d repeated_ack=%0d wrong_or_hung=%0d", checked, late, early, repeats, wrong);
    if (checked == 122 && wrong == 0 &&
        (($test$plusargs("EXPECT_LATE") && late > 0) ||
         (!$test$plusargs("EXPECT_LATE") && late == 0 && early == 0 && repeats == 0)))
      $display("RESPONSE_VERDICT_OK");
    else $display("FAIL response timing verdict");
    $finish;
  end
endmodule
