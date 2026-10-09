`timescale 1ns/1ps
/*
 * Packet receive window in mntzorro.v, end to end: Zorro III pins, the ARM
 * S_AXI register port and an AXI DDR read model.  The ARM is emulated by
 * S_AXI writes (mailbox, fence) and by acknowledging register writes the
 * way the main loop does (slv_reg0 bit 31).  Every read is checked against
 * the DDR model; prints PASS/FAIL per case and PW_VERDICT_OK/FAIL.
 */
module pw_tb;
  localparam BOARD   = 32'h48000000;
  localparam BACKLOG = 32'h3fe00000;

  reg clk = 0;
  reg rst_n = 0;                      // fabric reset, released after 10 cycles
  always #5 clk = ~clk;

  reg  [22:0] za_drv;  reg za_oe = 0;
  reg  [15:0] zd_drv;  reg zd_oe = 0;
  wire [22:0] ZORRO_ADDR = za_oe ? za_drv : 23'bz;
  wire [15:0] ZORRO_DATA = zd_oe ? zd_drv : 16'bz;
  reg ZORRO_READ = 1, ZORRO_NUDS = 1, ZORRO_NLDS = 1, ZORRO_NDS1 = 1, ZORRO_NDS0 = 1;
  reg ZORRO_NCCS = 1, ZORRO_NFCS = 1, ZORRO_DOE = 0, ZORRO_NIORST = 1, ZORRO_NCFGIN = 1;
  wire ZORRO_NDTACK;

  // ---- DDR read model: a header at each slot base, a hash elsewhere ----
  wire [31:0] araddr; wire [3:0] arlen; wire [1:0] arburst; wire arvalid;
  reg  arready = 1;
  reg  [31:0] rdata = 0; reg rvalid = 0; reg rlast = 0;
  integer ar_count = 0, errors = 0, lat = 20;
  reg [31:0] last_ar = 0;
  reg [11:0] slot_len [0:127];
  reg [15:0] slot_ser [0:127];
  function [31:0] model(input [31:0] a);
    reg [31:0] off; reg [6:0] s;
    begin
      off = a - BACKLOG; s = off[17:11];
      if (a >= BACKLOG && a < BACKLOG + 32'h40000 && off[10:0] == 0)
        model = {slot_ser[s][7:0], slot_ser[s][15:8], slot_len[s][7:0], 4'b0, slot_len[s][11:8]};
      else
        model = (a * 32'h9e3779b1) ^ 32'h5a5a0000;
    end
  endfunction
  reg [31:0] q_addr [0:15]; reg [4:0] q_len [0:15];
  integer q_head = 0, q_tail = 0, beat = 0, wait_cnt = 0;
  always @(posedge clk) begin
    if (arvalid && arready) begin
      q_addr[q_tail % 16] <= araddr; q_len[q_tail % 16] <= arlen + 1;
      q_tail <= q_tail + 1; ar_count <= ar_count + 1; last_ar <= araddr;
    end
    rvalid <= 0; rlast <= 0;
    if (q_head != q_tail) begin
      if (wait_cnt < lat) wait_cnt <= wait_cnt + 1;
      else begin
        rvalid <= 1;
        rdata  <= model(q_addr[q_head % 16] + beat * 4);
        if (beat + 1 == q_len[q_head % 16]) begin
          rlast <= 1; beat <= 0; q_head <= q_head + 1; wait_cnt <= 0;
        end else beat <= beat + 1;
      end
    end
  end

  // ---- S_AXI master (the ARM) ----
  reg [7:0] s_awaddr = 0, s_araddr = 0; reg s_awvalid = 0, s_wvalid = 0, s_arvalid = 0;
  reg [31:0] s_wdata = 0; wire s_awready, s_wready, s_bvalid, s_arready, s_rvalid;
  wire [31:0] s_rdata; wire [1:0] s_bresp, s_rresp;
  // Sample 1 ns after each edge: a handshake happens on the edge that follows
  // a cycle in which valid and ready are both high.
  task axi_write(input [7:0] a, input [31:0] d);
    begin
      @(posedge clk); #1 s_awaddr = a; s_wdata = d; s_awvalid = 1; s_wvalid = 1;
      while (!(s_awready && s_wready)) begin @(posedge clk); #1; end
      @(posedge clk); #1 s_awvalid = 0; s_wvalid = 0;
      while (!s_bvalid) begin @(posedge clk); #1; end
      @(posedge clk); #1;
    end
  endtask
  task axi_read(input [7:0] a, output [31:0] d);
    begin
      @(posedge clk); #1 s_araddr = a; s_arvalid = 1;
      while (!s_arready) begin @(posedge clk); #1; end
      @(posedge clk); #1 s_arvalid = 0;
      while (!s_rvalid) begin @(posedge clk); #1; end
      d = s_rdata;
      @(posedge clk); #1;
    end
  endtask
  localparam MB = 8'h40; // mailbox word k at 0x40 + 4k
  task mb_w(input [3:0] k, input [31:0] d); axi_write(MB + {k, 2'b00}, d); endtask
  task mb_r(input [3:0] k, output [31:0] d); axi_read(MB + {k, 2'b00}, d); endtask

  // The ARM main loop acknowledges forwarded Zorro register writes.
  always @(posedge clk) begin
    if (dut.zorro_ram_write_request && !dut.slv_reg0[31]) dut.slv_reg0[31] = 1;
    else if (!dut.zorro_ram_write_request && dut.slv_reg0[31]) dut.slv_reg0[31] = 0;
  end

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
    .m00_axi_aclk(clk), .m00_axi_aresetn(rst_n),
    .m00_axi_awready(1'b1), .m00_axi_wready(1'b1), .m00_axi_bresp(2'b00), .m00_axi_bvalid(1'b0),
    .m00_axi_arready(arready), .m00_axi_araddr(araddr), .m00_axi_arlen(arlen), .m00_axi_arburst(arburst),
    .m00_axi_arvalid(arvalid), .m00_axi_rdata(rdata), .m00_axi_rresp(2'b00), .m00_axi_rlast(rlast), .m00_axi_rvalid(rvalid),
    .m01_axi_aclk(clk), .m01_axi_aresetn(1'b1), .m01_axi_awready(1'b1), .m01_axi_wready(1'b1),
    .m01_axi_bresp(2'b00), .m01_axi_bvalid(1'b0),
    .video_control_vblank_in(2'b00), .source_sync_diagnostic(64'd0),
    .S_AXI_ACLK(clk), .S_AXI_ARESETN(rst_n),
    .S_AXI_AWADDR(s_awaddr), .S_AXI_AWPROT(3'b0), .S_AXI_AWVALID(s_awvalid), .S_AXI_AWREADY(s_awready),
    .S_AXI_WDATA(s_wdata), .S_AXI_WSTRB(4'hf), .S_AXI_WVALID(s_wvalid), .S_AXI_WREADY(s_wready),
    .S_AXI_BRESP(s_bresp), .S_AXI_BVALID(s_bvalid), .S_AXI_BREADY(1'b1),
    .S_AXI_ARADDR(s_araddr), .S_AXI_ARPROT(3'b0), .S_AXI_ARVALID(s_arvalid), .S_AXI_ARREADY(s_arready),
    .S_AXI_RDATA(s_rdata), .S_AXI_RRESP(s_rresp), .S_AXI_RVALID(s_rvalid), .S_AXI_RREADY(1'b1)
  );

  // ---- Zorro III cycles ----
  integer hang;
  task z3cycle(input [31:0] a, input rd, input [1:0] lanes, input [31:0] wd, output [31:0] got);
    begin
      za_drv = {a[23:2], 1'b0}; zd_drv = {a[31:24], 8'h00};
      za_oe = 1; zd_oe = 1; ZORRO_READ = rd;
      #30 ZORRO_NFCS = 0;
      #40 za_oe = 0; zd_oe = !rd;
      if (!rd) begin zd_drv = wd[31:16]; za_drv = {wd[15:0], 7'h0}; za_oe = 1; end
      ZORRO_DOE = 1;
      #10 ZORRO_NUDS = !lanes[1]; ZORRO_NLDS = !lanes[1]; ZORRO_NDS1 = !lanes[0]; ZORRO_NDS0 = !lanes[0];
      for (hang = 0; hang < 20000 && ZORRO_NDTACK !== 1'b1; hang = hang + 1) #10;
      if (ZORRO_NDTACK !== 1'b1) begin
        $display("FAIL z3 cycle at %h got no DTACK (state %0d)", a, dut.zorro_state); errors = errors + 1;
      end
      #20;
      got = {dut.data_z3_hi16, dut.data_z3_low16};
      ZORRO_NUDS = 1; ZORRO_NLDS = 1; ZORRO_NDS1 = 1; ZORRO_NDS0 = 1;
      ZORRO_DOE = 0; za_oe = 0; zd_oe = 0;
      #10 ZORRO_NFCS = 1;
      for (hang = 0; hang < 3000 && ZORRO_NDTACK !== 1'b0; hang = hang + 1) #10;
      #60;
    end
  endtask
  function [31:0] swapped(input [31:0] r);
    swapped = {r[7:0], r[15:8], r[23:16], r[31:24]};
  endfunction
  task zread(input [31:0] off, output [31:0] got);
    z3cycle(BOARD + off, 1, 2'b11, 0, got);
  endtask
  task zack(input [15:0] serial);
    reg [31:0] dummy;
    z3cycle(BOARD + 32'h80, 0, 2'b01, {16'h0, serial}, dummy);
  endtask
  task check(input cond, input [511:0] what);
    begin
      if (cond) $display("PASS %0s", what);
      else begin $display("FAIL %0s", what); errors = errors + 1; end
    end
  endtask

  // ---- ARM helpers ----
  task commit(input [6:0] slot, input [11:0] len, input [15:0] ser, input [31:0] cookie);
    reg [31:0] r;
    begin
      slot_len[slot] = len; slot_ser[slot] = ser;
      mb_w(1, cookie); mb_w(2, {ser, 4'b0, len}); mb_w(3, {23'b0, 2'b00, slot}); mb_w(4, cookie);
      mb_r(9, r);
      if (r[0]) begin $display("FAIL commit slot %0d rejected (LAST_RESULT %h)", slot, r); errors = errors + 1; end
    end
  endtask
  task expect_release(input [31:0] cookie, input [6:0] slot, input err, input [511:0] what);
    reg [31:0] st, c, m; integer t;
    begin
      st = 0;
      for (t = 0; t < 200 && !st[5]; t = t + 1) mb_r(0, st);
      mb_r(5, c); mb_r(6, m);
      check(st[5] && c == cookie && m[6:0] == slot && m[7] == err, what);
      mb_w(7, cookie);
    end
  endtask
  // Read one packet like the driver: header, then every payload longword.
  task read_packet(input [6:0] slot, input [511:0] what);
    reg [31:0] got, want; integer w, nw, bad;
    begin
      zread(32'h2000, got);
      want = swapped({slot_ser[slot][7:0], slot_ser[slot][15:8], slot_len[slot][7:0], 4'b0, slot_len[slot][11:8]});
      bad = (got !== want);
      if (bad) $display("INFO %0s header got %h want %h", what, got, want);
      nw = (slot_len[slot] + 7) / 4;
      for (w = 1; w < nw; w = w + 1) begin
        zread(32'h2000 + w * 4, got);
        want = swapped(model(BACKLOG + {slot, 11'h0} + w * 4));
        if (got !== want) begin
          if (!bad) $display("INFO %0s word %0d got %h want %h", what, w, got, want);
          bad = bad + 1;
        end
      end
      zread(32'h2000 + nw * 4, got);   // past the padded frame: rejected
      check(bad == 0 && got == 0, what);
    end
  endtask

  integer i; reg [31:0] got, r;
  initial begin
    $timeformat(-9, 0, " ns", 8);
    for (i = 0; i < 128; i = i + 1) begin slot_len[i] = 0; slot_ser[i] = 0; end
    repeat (10) @(posedge clk); rst_n = 1;
    repeat (20) @(posedge clk);
    dut.z3_ram_low = BOARD; dut.z3_confdone = 1; dut.slv_reg4 = 3;
    dut.zorro_state = 9; repeat (4) @(posedge clk); dut.zorro_state = 12; repeat (10) @(posedge clk);

    // P1 legacy: no packet mode, window and card memory through the arbiter foreground
    slot_len[3] = 100; slot_ser[3] = 16'h0777;
    zread(32'h2000, got);
    check(got == swapped(model(BACKLOG + {7'd3, 11'h0})), "P1 legacy window header via arbiter fg");
    zread(32'h20000, got);
    check(got == swapped(model(last_ar)), "P1 legacy card memory via arbiter fg");

    // P2 capability; negotiate packet mode (stopped): window reads zero, not DDR
    axi_write(8'h24, 1);
    zread(32'h2000, got); check(got == 0, "P2 packet mode, stopped: window reads zero");
    axi_read(8'h24, r); check(r[0] && r[3] && !r[4], "P2 status: host fence done, pkt_mode, not running");

    // P3 mailbox flush + rearm, host resume
    mb_w(8, 1); repeat (50) @(posedge clk);
    mb_r(0, r); check(r[2] && r[3], "P3 mailbox HALTED and drained after flush");
    mb_w(8, 2); axi_write(8'h24, 2);
    axi_read(8'h24, r); check(r[4] && !r[0], "P3 running, host admitted");
    zread(32'h2000, got); check(got == 0, "P3 running, empty: window reads zero");

    // P4 one packet: header + payload from the bank, then ACK -> release
    commit(7'd5, 12'd60, 16'h1234, 32'd1);
    read_packet(7'd5, "P4 packet slot 5 header+payload from bank");
    axi_read(8'h24, r); check(r[2], "P4 status b2 packet_valid while presented");
    zack(16'h1234);
    expect_release(32'd1, 7'd5, 0, "P4 ACK released slot 5 cookie 1");
    zread(32'h2000, got); check(got == 0, "P4 after ACK the window is empty");

    // P5 two packets in flight: the second fills while the first is read
    commit(7'd6, 12'd1514, 16'h2000, 32'd2);
    commit(7'd7, 12'd1514, 16'h2001, 32'd3);
    read_packet(7'd6, "P5 first of two full-size packets");
    zack(16'h2000); expect_release(32'd2, 7'd6, 0, "P5 release first");
    read_packet(7'd7, "P5 second packet (overlapped fill)");
    zack(16'h2001); expect_release(32'd3, 7'd7, 0, "P5 release second");

    // P6 stale ACK: without reading the header there is no snapshot -> ignored
    commit(7'd8, 12'd64, 16'h3000, 32'd4);
    repeat (300) @(posedge clk);
    zack(16'h3000); repeat (50) @(posedge clk);
    mb_r(0, r); check(!r[5], "P6 ACK without header read is ignored");
    zread(32'h2000, got);            // header read takes the snapshot
    zack(16'h2fff); repeat (50) @(posedge clk);
    mb_r(0, r); check(!r[5], "P6 ACK with wrong serial is ignored");
    zack(16'h3000); expect_release(32'd4, 7'd8, 0, "P6 matching ACK after header read releases");

    // P7 error packet (length 10): dropped by the FPGA, released with error
    commit(7'd9, 12'd10, 16'h4000, 32'd5);
    expect_release(32'd5, 7'd9, 1, "P7 invalid descriptor auto-released with error");
    zread(32'h2000, got); check(got == 0, "P7 window never shows the error packet");

    // P8 a read that arrives while the head is still filling waits for it
    lat = 400;                       // ~4 us DDR latency
    commit(7'd10, 12'd200, 16'h5000, 32'd6);
    read_packet(7'd10, "P8 read during fill waits and returns the packet");
    zack(16'h5000); expect_release(32'd6, 7'd10, 0, "P8 release");
    lat = 20;

    // P9 foreground card-memory read while a fill is in flight
    commit(7'd11, 12'd1514, 16'h6000, 32'd7);
    zread(32'h30000, got); check(got == swapped(model(dut.zfg_araddr)), "P9 card memory read during packet fill");
    read_packet(7'd11, "P9 packet still intact");
    zack(16'h6000); expect_release(32'd7, 7'd11, 0, "P9 release");

    // P10 host stop: window zero, ACK ignored, status reports the fence
    commit(7'd12, 12'd64, 16'h7000, 32'd8);
    zread(32'h2000, got);
    axi_write(8'h24, 1);
    zread(32'h2000, got); check(got == 0, "P10 stopped: window zero");
    zack(16'h7000); repeat (50) @(posedge clk);
    mb_r(0, r); check(!r[5], "P10 stopped: ACK ignored (snapshot invalidated)");
    axi_read(8'h24, r); check(r[0] && r[1], "P10 status: host and link fence complete");

    if (errors == 0) $display("PW_VERDICT_OK");
    else $display("PW_VERDICT_FAIL errors=%0d", errors);
    $finish;
  end
  initial begin #20000000; $display("PW_VERDICT_FAIL timeout"); $finish; end
endmodule
