`timescale 1ns/1ps
/*
 * Receive-window read-ahead in mntzorro.v, driven through the Zorro III pins
 * against a modelled AXI read slave.  Autoconfig is skipped: the testbench
 * writes the configured state into the DUT once and lets it run.
 *
 * Every read's data is checked against the DDR model; the AXI read requests
 * are counted and their length checked.  Prints PASS/FAIL per case and a
 * final verdict.
 */
module rxpf_tb;
  localparam BOARD   = 32'h48000000;
  localparam BACKLOG = 32'h3fe00000;

  reg clk = 0;
  always #5 clk = ~clk;               // 100 MHz S_AXI_ACLK / m00_axi_aclk

  // Zorro pins
  reg  [22:0] za_drv;  reg za_oe = 0;
  reg  [15:0] zd_drv;  reg zd_oe = 0;
  wire [22:0] ZORRO_ADDR = za_oe ? za_drv : 23'bz;
  wire [15:0] ZORRO_DATA = zd_oe ? zd_drv : 16'bz;
  reg ZORRO_READ = 1, ZORRO_NUDS = 1, ZORRO_NLDS = 1, ZORRO_NDS1 = 1, ZORRO_NDS0 = 1;
  reg ZORRO_NCCS = 1, ZORRO_NFCS = 1, ZORRO_DOE = 0, ZORRO_NIORST = 1, ZORRO_NCFGIN = 1;
  wire ZORRO_NDTACK;

  // AXI read slave model
  wire [31:0] araddr; wire [3:0] arlen; wire [1:0] arburst; wire arvalid;
  reg  arready = 1;
  reg  [31:0] rdata = 0; reg rvalid = 0; reg rlast = 0;
  integer ar_count = 0;
  reg [31:0] gen = 0;                  // bumps model data: "the ARM rewrote DDR"

  function [31:0] model(input [31:0] a, input [31:0] g);
    model = (a * 32'h9e3779b1) ^ (g * 32'h85ebca6b) ^ 32'h5a5a0000;
  endfunction

  // a queue of outstanding bursts, served in order after a fixed latency
  reg [31:0] q_addr [0:15]; reg [4:0] q_len [0:15]; reg [31:0] q_gen [0:15];
  integer q_head = 0, q_tail = 0, beat = 0, wait_cnt = 0;
  // +RANDOM_ARREADY: the interconnect holds arready low at random
  reg random_arready = 0;
  initial random_arready = $test$plusargs("RANDOM_ARREADY");
  // +RAGGED: 5..68 cycle latency per burst and random gaps between beats
  reg ragged = 0;
  integer lat = 20;
  initial ragged = $test$plusargs("RAGGED");
  always @(posedge clk) if (random_arready) arready <= $random;
  // late_arready: arready follows arvalid one cycle late, as an interconnect
  // that is still waking up -- the shape that exposes a handshake that moves
  // on before arvalid is dropped.  drop_next: deliver one beat of the next
  // burst and lose the rest with no rlast, as an interconnect reset would.
  reg late_arready = 0, drop_next = 0;
  always @(posedge clk) if (late_arready) arready <= arvalid;
  reg [31:0] last_arlen;
  always @(posedge clk) begin
    if (arvalid && arready) begin
      q_addr[q_tail % 16] <= araddr; q_len[q_tail % 16] <= arlen + 1;
      q_gen[q_tail % 16] <= gen; q_tail <= q_tail + 1;
      ar_count <= ar_count + 1; last_arlen <= arlen;
      if (arlen != 0 && arburst != 2'b01) begin
        $display("FAIL burst with arburst=%0d", arburst); errors = errors + 1;
      end
    end
    rvalid <= 0; rlast <= 0;
    if (q_head != q_tail) begin
      if (wait_cnt < lat) wait_cnt <= wait_cnt + 1;  // ~200 ns DDR latency by default
      else if (ragged && beat != 0 && ($random & 3) == 0) begin
        // a cycle with no beat inside the burst
      end else begin
        rvalid <= 1;
        rdata  <= model(q_addr[q_head % 16] + beat * 4, q_gen[q_head % 16]);
        if (drop_next && q_len[q_head % 16] > 1) begin
          // one beat, then the rest of this burst and everything queued is gone
          drop_next <= 0; q_head <= q_tail; beat <= 0; wait_cnt <= 0;
        end else
        if (beat + 1 == q_len[q_head % 16]) begin
          rlast <= 1; beat <= 0; q_head <= q_head + 1; wait_cnt <= 0;
          if (ragged) lat <= 5 + ($random & 63);
        end else beat <= beat + 1;
      end
    end
  end

  integer errors = 0, hung = 0, hang = 0;

  MNTZorro_v0_1_S00_AXI dut (
    .ZORRO_ADDR(ZORRO_ADDR), .ZORRO_DATA(ZORRO_DATA),
    .ZORRO_NBGN(1'b1), .ZORRO_READ(ZORRO_READ), .ZORRO_NUDS(ZORRO_NUDS), .ZORRO_NLDS(ZORRO_NLDS),
    .ZORRO_NDS1(ZORRO_NDS1), .ZORRO_NDS0(ZORRO_NDS0), .ZORRO_NCCS(ZORRO_NCCS), .ZORRO_NFCS(ZORRO_NFCS),
    .ZORRO_DOE(ZORRO_DOE), .ZORRO_NIORST(ZORRO_NIORST), .ZORRO_NCFGIN(ZORRO_NCFGIN),
    .ZORRO_E7M(1'b0), .ZORRO_C28D(1'b0),
    .VCAP_VSYNC(1'b0), .VCAP_HSYNC(1'b0),
    .VCAP_G0(1'b0), .VCAP_G1(1'b0), .VCAP_G2(1'b0), .VCAP_G3(1'b0), .VCAP_G4(1'b0), .VCAP_G5(1'b0), .VCAP_G6(1'b0), .VCAP_G7(1'b0),
    .VCAP_B0(1'b0), .VCAP_B1(1'b0), .VCAP_B2(1'b0), .VCAP_B3(1'b0), .VCAP_B4(1'b0), .VCAP_B5(1'b0), .VCAP_B6(1'b0), .VCAP_B7(1'b0),
    .VCAP_R0(1'b0), .VCAP_R1(1'b0), .VCAP_R2(1'b0), .VCAP_R3(1'b0), .VCAP_R4(1'b0), .VCAP_R5(1'b0), .VCAP_R6(1'b0), .VCAP_R7(1'b0),
    .ZORRO_NDTACK(ZORRO_NDTACK),
    .m00_axi_aclk(clk), .m00_axi_aresetn(1'b1),
    .m00_axi_awready(1'b1), .m00_axi_wready(1'b1), .m00_axi_bresp(2'b00), .m00_axi_bvalid(1'b0),
    .m00_axi_arready(arready), .m00_axi_araddr(araddr), .m00_axi_arlen(arlen), .m00_axi_arburst(arburst),
    .m00_axi_arvalid(arvalid), .m00_axi_rdata(rdata), .m00_axi_rresp(2'b00), .m00_axi_rlast(rlast), .m00_axi_rvalid(rvalid),
    .m01_axi_aclk(clk), .m01_axi_aresetn(1'b1), .m01_axi_awready(1'b1), .m01_axi_wready(1'b1),
    .m01_axi_bresp(2'b00), .m01_axi_bvalid(1'b0),
    .video_control_vblank_in(2'b00), .source_sync_diagnostic(64'd0),
    .S_AXI_ACLK(clk), .S_AXI_ARESETN(1'b1),
    .S_AXI_AWADDR(0), .S_AXI_AWPROT(3'b0), .S_AXI_AWVALID(1'b0), .S_AXI_WDATA(0), .S_AXI_WSTRB(0),
    .S_AXI_WVALID(1'b0), .S_AXI_BREADY(1'b1), .S_AXI_ARADDR(0), .S_AXI_ARPROT(3'b0),
    .S_AXI_ARVALID(1'b0), .S_AXI_RREADY(1'b1)
  );

  // one Zorro III longword (or word) cycle at absolute address a
  task z3cycle(input [31:0] a, input rd, input [1:0] lanes /*3=long,2=hi word,1=lo word*/,
               output [31:0] got, output integer cycles_ns);
    integer t0;
    begin
      t0 = $time;
      za_drv = {a[23:2], 1'b0}; zd_drv = {a[31:24], 8'h00};
      za_oe = 1; zd_oe = 1; ZORRO_READ = rd;
      #30 ZORRO_NFCS = 0;
      #40 za_oe = 0; zd_oe = !rd;
      if (!rd) begin zd_drv = 16'hdead; za_drv = {16'hbeef, 7'h0}; za_oe = 1; end
      ZORRO_DOE = 1;
      #10 ZORRO_NUDS = !lanes[1]; ZORRO_NLDS = !lanes[1]; ZORRO_NDS1 = !lanes[0]; ZORRO_NDS0 = !lanes[0];
      for (hang = 0; hang < 3000 && ZORRO_NDTACK !== 1'b1; hang = hang + 1) #10;
      if (ZORRO_NDTACK !== 1'b1) begin hung = hung + 1; $display("INFO z3 cycle at %h got no DTACK in 30 us (state %0d busy %0d in_ram %0d fcs %0d)", a, dut.zorro_state, dut.rxpf_busy, dut.z3addr_in_ram, dut.z3_fcs_state); end
      #20;
      got = {dut.data_z3_hi16, dut.data_z3_low16};
      ZORRO_NUDS = 1; ZORRO_NLDS = 1; ZORRO_NDS1 = 1; ZORRO_NDS0 = 1;
      ZORRO_DOE = 0; za_oe = 0; zd_oe = 0;
      #10 ZORRO_NFCS = 1;
      for (hang = 0; hang < 3000 && ZORRO_NDTACK !== 1'b0; hang = hang + 1) #10;
      #60;
      cycles_ns = $time - t0;
    end
  endtask

  function [31:0] swapped(input [31:0] r);   // what data_z3_hi16/low16 hold for an AXI word
    swapped = {r[7:0], r[15:8], r[23:16], r[31:24]};
  endfunction

  function [31:0] ddr(input [31:0] off, input [20:0] sel);
    ddr = (BACKLOG - 32'h2000) + off + {sel, 11'h0};
  endfunction

  task expect_read(input [31:0] off, input [20:0] sel, input [1:0] lanes, input [31:0] g, input [127:0] what);
    reg [31:0] got, want; integer ns;
    begin
      z3cycle(BOARD + off, 1, lanes, got, ns);
      want = swapped(model(ddr(off, sel) & 32'hfffffffc, g));
      if (got !== want) begin
        $display("FAIL %0s off=%h got=%h want=%h", what, off, got, want); errors = errors + 1;
      end
    end
  endtask

  integer i, n0, ns, k; reg [31:0] got;
  initial begin
    $timeformat(-9, 0, " ns", 8);
    if ($test$plusargs("BOOT")) begin : boot_arm
      integer n0b;
      repeat (20) @(posedge clk);
      dut.z3_ram_low = BOARD; dut.z3_confdone = 1; dut.slv_reg4 = 2;
      dut.zorro_state = 9; repeat (4) @(posedge clk); dut.zorro_state = 12; repeat (10) @(posedge clk);
      // B1: a card-memory read while arready lags arvalid: exactly one request
      late_arready = 1; arready = 0;
      n0b = ar_count;
      z3cycle(BOARD + 32'h20000, 1, 2'b11, got, ns);
      repeat (200) @(posedge clk);
      $display("%s late arready, non-window read: %0d request(s) (want 1)", (ar_count - n0b == 1) ? "PASS" : "FAIL", ar_count - n0b);
      if (ar_count - n0b != 1) errors = errors + 1;
      n0b = ar_count;
      z3cycle(BOARD + 32'h2000, 1, 2'b11, got, ns);
      repeat (200) @(posedge clk);
      $display("%s late arready, window read: %0d request(s) (want 1)", (ar_count - n0b == 1) ? "PASS" : "FAIL", ar_count - n0b);
      if (ar_count - n0b != 1) errors = errors + 1;
      late_arready = 0; @(posedge clk); #1 arready = 1; @(posedge clk);
      // B2: a burst loses its beats (interconnect reset); a Zorro reset follows,
      // as the Amiga resets while the card comes up.  Afterwards card memory
      // must still be readable.
      dut.slv_reg4 = 5; repeat (4) @(posedge clk);
      drop_next = 1;
      hung = 0;
      z3cycle(BOARD + 32'h2000, 1, 2'b11, got, ns);   // gets its own beat
      z3cycle(BOARD + 32'h2004, 1, 2'b11, got, ns);   // wants a beat that never comes
      ZORRO_NIORST = 0; repeat (20) @(posedge clk); ZORRO_NIORST = 1; repeat (20) @(posedge clk);
      dut.z3_ram_low = BOARD; dut.z3_confdone = 1;
      dut.zorro_state = 9; repeat (4) @(posedge clk); dut.zorro_state = 12; repeat (10) @(posedge clk);
      hung = 0;
      z3cycle(BOARD + 32'h20000, 1, 2'b11, got, ns);  // framebuffer-style read
      z3cycle(BOARD + 32'h2000, 1, 2'b11, got, ns);   // window read
      $display("%s after lost beats + Zorro reset: %0d hung read(s) (want 0)", hung == 0 ? "PASS" : "FAIL", hung);
      if (hung != 0) errors = errors + 1;
      $display("%s rxpf_tb: %0d error(s)", errors == 0 ? "PASS" : "FAIL", errors);
      if (errors == 0) $display("RXPF_VERDICT_OK");
      $finish;
    end
    repeat (20) @(posedge clk);
    // configured at BOARD, slot 3
    dut.z3_ram_low = BOARD; dut.z3_confdone = 1; dut.slv_reg4 = 3;
    dut.zorro_state = 9;    // CONFIGURED: derives the window bounds
    repeat (4) @(posedge clk);
    dut.zorro_state = 12;   // Z3_IDLE
    repeat (10) @(posedge clk);
    $display("INFO configured: ram %h-%h reg %h-%h", dut.z3_ram_low, dut.z3_ram_high, dut.z3_reg_low, dut.z3_reg_high);

    // 1. a 1500-byte frame read front to back: one burst per 64 bytes
    n0 = ar_count;
    for (i = 0; i < 375; i = i + 1) expect_read(32'h2000 + i*4, 3, 2'b11, gen, "seq");
    $display("%s seq: %0d longs, %0d AXI requests (want 24)", (ar_count - n0 == 24) ? "PASS" : "FAIL",
             375, ar_count - n0);
    if (ar_count - n0 != 24) errors = errors + 1;

    // 2. header poll: the same address twice sees DDR change in between
    expect_read(32'h2000, 3, 2'b11, gen, "poll-a");
    gen = gen + 1;
    n0 = ar_count;
    expect_read(32'h2000, 3, 2'b11, gen, "poll-b");
    $display("%s poll re-read goes to DDR (%0d request)", (ar_count - n0 == 1) ? "PASS" : "FAIL", ar_count - n0);
    if (ar_count - n0 != 1) errors = errors + 1;

    // 3. a write retires the line
    expect_read(32'h2100, 3, 2'b11, gen, "w-a");
    z3cycle(BOARD + 32'h9000, 0, 2'b11, got, ns);          // TX window write
    gen = gen + 1;
    n0 = ar_count;
    expect_read(32'h2104, 3, 2'b11, gen, "w-b");
    $display("%s write retires the line (%0d request)", (ar_count - n0 == 1) ? "PASS" : "FAIL", ar_count - n0);
    if (ar_count - n0 != 1) errors = errors + 1;

    // 4. a new presented slot retires the line
    expect_read(32'h2200, 3, 2'b11, gen, "s-a");
    dut.slv_reg4 = 9;
    repeat (4) @(posedge clk);
    n0 = ar_count;
    expect_read(32'h2204, 9, 2'b11, gen, "s-b");
    $display("%s slot change retires the line (%0d request)", (ar_count - n0 == 1) ? "PASS" : "FAIL", ar_count - n0);
    if (ar_count - n0 != 1) errors = errors + 1;

    // 5. word reads.  Zorro III puts the same longword address on the bus for
    //    A and A+2 (only the lane strobes differ), so the second word is not
    //    "forward" and goes back to DDR, as every read did before; A+4 hits.
    n0 = ar_count;
    expect_read(32'h2300, 9, 2'b10, gen, "wd-a");
    expect_read(32'h2302, 9, 2'b01, gen, "wd-b");
    expect_read(32'h2304, 9, 2'b10, gen, "wd-c");
    $display("%s word reads: %0d requests (want 2)", (ar_count - n0 == 2) ? "PASS" : "FAIL", ar_count - n0);
    if (ar_count - n0 != 2) errors = errors + 1;

    // 6. 4 KB boundary: slot 1 + 0x7d8 ends 40 bytes before a 4 KB line
    dut.slv_reg4 = 1; repeat (4) @(posedge clk);
    n0 = ar_count;
    expect_read(32'h27d8, 1, 2'b11, gen, "4k");
    $display("%s burst near 4 KB boundary: arlen=%0d (want 9)", (last_arlen == 9) ? "PASS" : "FAIL", last_arlen);
    if (last_arlen != 9) errors = errors + 1;
    for (k = 1; k < 10; k = k + 1) expect_read(32'h27d8 + k*4, 1, 2'b11, gen, "4k-seq");
    if (ar_count - n0 != 1) begin $display("FAIL 4k line refetched"); errors = errors + 1; end

    // 7. outside the window: single beats, unchanged
    n0 = ar_count;
    z3cycle(BOARD + 32'h20000, 1, 2'b11, got, ns);
    $display("%s non-window read single beat: arlen=%0d", (last_arlen == 0 && ar_count - n0 == 1) ? "PASS" : "FAIL", last_arlen);
    if (!(last_arlen == 0 && ar_count - n0 == 1)) errors = errors + 1;

    // 8. timing: a hit versus a miss, in Zorro cycle length
    dut.slv_reg4 = 4; repeat (4) @(posedge clk);
    z3cycle(BOARD + 32'h2000, 1, 2'b11, got, ns); $display("INFO miss cycle %0d ns", ns);
    z3cycle(BOARD + 32'h2004, 1, 2'b11, got, ns); $display("INFO hit  cycle %0d ns", ns);

    $display("%s rxpf_tb: %0d error(s)", errors == 0 ? "PASS" : "FAIL", errors);
    if (errors == 0) $display("RXPF_VERDICT_OK");
    $finish;
  end

  initial begin #20000000 $display("FAIL timeout"); $finish; end
endmodule
