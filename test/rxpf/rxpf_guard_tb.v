`timescale 1ns/1ps
// Reset/slot invalidation after pre-enabling an actual received word. The
// transaction must retry, not acknowledge an invalidated output pipeline.
module rxpf_guard_tb;
  rxpf_tb #(.EXTERNAL_DRIVER(1)) tb();
  reg [31:0] got;
  integer ns, before_ar, errors = 0, cases = 0;
  reg observe = 0;
  always @(posedge tb.ZORRO_NDTACK) if (observe &&
      (!tb.aresetn || !tb.dut.rxpf_valid ||
       tb.dut.rxpf_select != tb.dut.eth_rx_frame_select)) begin
    $display("FAIL ACK for invalidated line"); errors = errors + 1;
  end
  initial begin
    repeat (20) @(posedge tb.clk);
    tb.dut.z3_ram_low = tb.BOARD; tb.dut.z3_confdone = 1;
    tb.dut.slv_reg4 = 3; tb.dut.zorro_state = 9;
    repeat (4) @(posedge tb.clk); tb.dut.zorro_state = 12;
    repeat (10) @(posedge tb.clk);
    tb.z3cycle(tb.BOARD + 'h2600, 1, 2'b11, got, ns);
    repeat (20) @(posedge tb.clk);
    before_ar = tb.ar_count; observe = 1;
    fork
      tb.z3cycle(tb.BOARD + 'h2604, 1, 2'b11, got, ns);
      begin
        wait (tb.dut.zorro_state == 66); #1; tb.aresetn = 0;
        @(posedge tb.clk); #1;
        if (tb.dut.dataout_z3 || tb.ZORRO_NDTACK) begin
          $display("FAIL guard did not withdraw on fabric reset"); errors = errors + 1;
        end
        repeat (2) @(negedge tb.clk); tb.aresetn = 1;
      end
    join
    if (got !== tb.swapped(tb.model(tb.ddr('h2604,3),tb.gen)) ||
        tb.ar_count-before_ar != 1 || tb.hung != 0) begin
      $display("FAIL fabric guard retry/data/count"); errors = errors + 1;
    end
    cases = cases + 1;
    observe = 0;
    tb.z3cycle(tb.BOARD + 'h2800, 1, 2'b11, got, ns);
    repeat (20) @(posedge tb.clk);
    before_ar = tb.ar_count; observe = 1;
    fork
      tb.z3cycle(tb.BOARD + 'h2804, 1, 2'b11, got, ns);
      begin
        wait (tb.dut.zorro_state == 66); #1; tb.dut.slv_reg4 = 4;
        // slv_reg4 is published into registered eth_rx_frame_select on
        // the next edge. Check withdrawal on the edge that observes it;
        // ACK is forbidden throughout by the monitor above.
        wait (tb.dut.eth_rx_frame_select == 4);
        @(posedge tb.clk); #1;
        if (tb.dut.dataout_z3 || tb.ZORRO_NDTACK) begin
          $display("FAIL guard did not withdraw on slot change"); errors = errors + 1;
        end
      end
    join
    if (got !== tb.swapped(tb.model(tb.ddr('h2804,4),tb.gen)) ||
        tb.ar_count-before_ar != 1 || tb.hung != 0) begin
      $display("FAIL slot guard retry/data/count"); errors = errors + 1;
    end
    cases = cases + 1;
    $display("GUARD cases=%0d errors=%0d",cases,errors);
    if (cases == 2 && errors == 0) $display("GUARD_VERDICT_OK");
    else $display("FAIL guard verdict");
    $finish;
  end
  initial begin #200000; $display("FAIL guard test timeout"); $finish; end
endmodule
