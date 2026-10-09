// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
module axilite_tb #(parameter TEST_ID_WIDTH = 2);
    localparam BASE = 32'h3fe00000;
    reg clk = 0;
    always #5 clk = !clk;
    reg aresetn = 0, flush_request = 0;
    wire csr_write;
    wire [3:0] csr_word, csr_wstrb, csr_read_word;
    wire [31:0] csr_wdata;
    wire csr_error;
    wire [31:0] csr_rdata;
    wire core_flush, core_flush_done, desc_valid, desc_ready;
    wire [6:0] desc_slot, release_slot;
    wire [11:0] desc_length;
    wire [15:0] desc_serial;
    wire [31:0] desc_cookie, release_cookie;
    wire [1:0] desc_csum;
    wire release_valid, release_ready, release_error;
`ifndef COMBINED_PACKET_ENGINE
    zz_eth_packet_mailbox mailbox (.*);
`endif

    wire packet_valid, packet_error, ack_ready, host_read_valid;
    wire [11:0] packet_length;
    wire [15:0] packet_serial;
    wire [31:0] packet_cookie, host_data;
    wire [1:0] packet_csum;
    reg host_read = 0, ack_valid = 0;
    reg [8:0] host_word = 0;
    reg [31:0] ack_cookie = 0;
    wire [31:0] araddr;
    wire [7:0] arlen;
    wire [2:0] arsize;
    wire [1:0] arburst;
    wire arvalid, arready, rready;
    reg [31:0] rdata = 0;
    reg [1:0] rresp = 0;
    reg rlast = 0, rvalid = 0;
`ifndef COMBINED_PACKET_ENGINE
    zz_eth_packet_window core (.flush(core_flush), .flush_done(core_flush_done), .*);
`endif

`ifdef COMBINED_PACKET_ENGINE
    localparam [TEST_ID_WIDTH-1:0] BG_ID = TEST_ID_WIDTH > 1 ? 2 : 0;
    reg foreground_pending=0, fg_arvalid=0, fg_rready=1;
    reg [31:0] fg_araddr=BASE+32'h20000;
    reg [7:0] fg_arlen=0;
    reg [1:0] fg_arburst=1;
    reg [3:0] fg_arcache=4'hf;
    reg [2:0] fg_arprot=3'h2;
    reg [TEST_ID_WIDTH-1:0] fg_arid=1;
    wire fg_arready, fg_rvalid, fg_rlast;
    wire [31:0] fg_rdata;
    wire [1:0] fg_rresp;
    wire [TEST_ID_WIDTH-1:0] fg_rid, arid;
    wire [3:0] arcache;
    wire [2:0] arprot;
    reg [TEST_ID_WIDTH-1:0] rid=0, bus_id=0;
`endif

    reg [31:0] memory [0:65535];
    reg allow_ar = 1, allow_r = 1, active = 0;
    integer word_index = 0, beats = 0;
    integer accepts = 0, commits = 0, requests = 0, releases = 0, flushes = 0;
    reg [31:0] accepted_cookie [0:31];
    reg stalled = 0;
    reg [68:0] saved_descriptor;
    wire [68:0] descriptor = {desc_slot, desc_length, desc_serial, desc_cookie, desc_csum};
    assign arready = aresetn && allow_ar && !active;
    always @(posedge clk) begin
        if (!aresetn) begin
            active <= 0; rvalid <= 0; rlast <= 0; stalled <= 0;
        end else begin
            if (csr_write && !csr_error && csr_word == 4) commits = commits + 1;
            if (desc_valid && desc_ready) begin
                accepted_cookie[accepts] = desc_cookie;
                accepts = accepts + 1;
                if (accepts > commits) $fatal(1, "descriptor accepted without COMMIT");
            end
            if (stalled && !core_flush && (!desc_valid || descriptor !== saved_descriptor))
                $fatal(1, "queued descriptor changed while core stalled");
            stalled <= desc_valid && !desc_ready;
            saved_descriptor <= descriptor;
            if (core_flush) flushes = flushes + 1;
            if (release_valid && release_ready) releases = releases + 1;
            if (arvalid && arready) begin
                if (active || arsize != 2 || arburst != 1 || arlen > 15)
                    $fatal(1, "invalid or duplicate AXI address");
                active <= 1; word_index <= (araddr-BASE)/4; beats <= arlen+1;
                requests = requests + 1;
`ifdef COMBINED_PACKET_ENGINE
                bus_id <= arid;
                if (fg_arready) begin
                    if (engine.bg_arready || arcache!==4'hf || arprot!==3'h2 || arid!=1)
                        $fatal(1,"engine foreground attribute/owner mismatch");
                end else if (!engine.bg_arready || arcache!==4'h3 || arprot!==3'h5 || arid!==BG_ID)
                    $fatal(1,"engine packet attribute/owner mismatch");
`endif
            end
            if (active && !rvalid && allow_r) begin
                rdata <= memory[word_index]; rresp <= 0; rlast <= beats == 1; rvalid <= 1;
`ifdef COMBINED_PACKET_ENGINE
                rid <= bus_id;
`endif
            end
            if (rvalid && rready) begin
                rvalid <= 0; word_index <= word_index+1; beats <= beats-1;
                if (rlast) active <= 0;
            end
        end
    end

    task clocks(input integer n);
        repeat(n) begin @(posedge clk); #1; end
    endtask
    reg [11:0] s_axi_awaddr = 0, s_axi_araddr = 0;
    reg [2:0] s_axi_awprot = 0, s_axi_arprot = 0;
    reg s_axi_awvalid = 0, s_axi_wvalid = 0, s_axi_arvalid = 0;
    wire s_axi_awready, s_axi_wready, s_axi_arready;
    reg [31:0] s_axi_wdata = 0;
    reg [3:0] s_axi_wstrb = 15;
    wire [31:0] s_axi_rdata;
    wire [1:0] s_axi_bresp, s_axi_rresp;
    wire s_axi_bvalid, s_axi_rvalid;
    reg s_axi_bready = 0, s_axi_rready = 0;
    reg quiesce_request = 0, resume = 0;
    wire quiesced, local_drained;
`ifdef COMBINED_PACKET_ENGINE
    // Deliberately distinct test attributes expose crossed-client wiring.
    zz_eth_packet_engine #(.ID_WIDTH(TEST_ID_WIDTH), .PACKET_ARCACHE(4'h3),
        .PACKET_ARPROT(3'h5), .PACKET_ARID(BG_ID)) engine (.*);
    assign csr_write=engine.csr_write;
    assign csr_word=engine.csr_word;
    assign csr_wstrb=engine.csr_wstrb;
    assign csr_wdata=engine.csr_wdata;
    assign csr_read_word=engine.csr_read_word;
    assign csr_rdata=engine.csr_rdata;
    assign csr_error=engine.csr_error;
    assign core_flush=engine.core_flush;
    assign desc_valid=engine.desc_valid;
    assign desc_ready=engine.desc_ready;
    assign desc_slot=engine.desc_slot;
    assign desc_length=engine.desc_length;
    assign desc_serial=engine.desc_serial;
    assign desc_cookie=engine.desc_cookie;
    assign desc_csum=engine.desc_csum;
    assign release_valid=engine.release_valid;
    assign release_ready=engine.release_ready;
    assign release_slot=engine.release_slot;
    assign release_cookie=engine.release_cookie;
    assign release_error=engine.release_error;
    wire mailbox_halted=engine.mailbox.mode==0;
`else
    zz_eth_packet_axilite adapter (.*);
    wire mailbox_halted=mailbox.mode==0;
`endif

    integer aw_count=0, w_count=0, b_count=0, ar_count=0, r_count=0, strobes=0;
    reg b_stalled=0, r_stalled=0, prior_write=0;
    reg [1:0] saved_bresp;
    reg [33:0] saved_response;
    always @(posedge clk) begin
        if (!aresetn) begin
            aw_count=0; w_count=0; b_count=0; ar_count=0; r_count=0;
            b_stalled<=0; r_stalled<=0; prior_write<=0;
        end else begin
            if (s_axi_awvalid && s_axi_awready) aw_count=aw_count+1;
            if (s_axi_wvalid && s_axi_wready) w_count=w_count+1;
            if (s_axi_arvalid && s_axi_arready) ar_count=ar_count+1;
            if (s_axi_bvalid && s_axi_bready) b_count=b_count+1;
            if (s_axi_rvalid && s_axi_rready) r_count=r_count+1;
            if (b_count>aw_count || b_count>w_count || r_count>ar_count)
                $fatal(1,"response without accepted request");
            if (b_stalled && (!s_axi_bvalid || s_axi_bresp!==saved_bresp))
                $fatal(1,"B response changed under backpressure");
            if (r_stalled && (!s_axi_rvalid || {s_axi_rresp,s_axi_rdata}!==saved_response))
                $fatal(1,"R response changed under backpressure");
            if (csr_write) begin
                strobes=strobes+1;
                if (prior_write) $fatal(1,"CSR write replayed");
            end
            prior_write<=csr_write;
            b_stalled<=s_axi_bvalid && !s_axi_bready; saved_bresp<=s_axi_bresp;
            r_stalled<=s_axi_rvalid && !s_axi_rready;
            saved_response<={s_axi_rresp,s_axi_rdata};
            if (local_drained && (s_axi_awready || s_axi_wready || s_axi_arready ||
                                  s_axi_bvalid || s_axi_rvalid || csr_write))
                $fatal(1,"local drain reported with live transaction");
        end
    end
    task send_aw(input [11:0] address);
        begin
            @(negedge clk); s_axi_awaddr=address; s_axi_awvalid=1;
            @(posedge clk); while (!s_axi_awready) @(posedge clk);
            @(negedge clk); s_axi_awvalid=0; s_axi_awaddr=12'hfff;
        end
    endtask
    task send_w(input [31:0] data, input [3:0] mask);
        begin
            @(negedge clk); s_axi_wdata=data; s_axi_wstrb=mask; s_axi_wvalid=1;
            @(posedge clk); while (!s_axi_wready) @(posedge clk);
            @(negedge clk); s_axi_wvalid=0; s_axi_wdata=32'hbadbad; s_axi_wstrb=0;
        end
    endtask
    task take_b(input [1:0] response, input integer delay_clocks);
        begin
            while (!s_axi_bvalid) clocks(1);
            clocks(delay_clocks);
            if (!s_axi_bvalid || s_axi_bresp!==response) $fatal(1,"wrong B response");
            @(negedge clk); s_axi_bready=1;
            @(posedge clk); #1;
            @(negedge clk); s_axi_bready=0;
        end
    endtask
    task write_bus(input [11:0] address, input [31:0] data, input [3:0] mask,
                   input integer order, input [1:0] response);
        integer before_strobes;
        begin
            before_strobes=strobes;
            if (order==0) begin send_aw(address); clocks(7); send_w(data,mask); end
            else if (order==1) begin send_w(data,mask); clocks(9); send_aw(address); end
            else fork send_aw(address); send_w(data,mask); join
            take_b(response,13);
            if (strobes != before_strobes+(response==0)) $fatal(1,"write did not issue exactly one CSR pulse");
        end
    endtask
    task send_ar(input [11:0] address);
        begin
            @(negedge clk); s_axi_araddr=address; s_axi_arvalid=1;
            @(posedge clk); while (!s_axi_arready) @(posedge clk);
            @(negedge clk); s_axi_arvalid=0; s_axi_araddr=12'hfff;
        end
    endtask
    task take_r(input [31:0] data, input [1:0] response, input integer delay_clocks);
        begin
            while (!s_axi_rvalid) clocks(1);
            clocks(delay_clocks);
            if (!s_axi_rvalid || s_axi_rdata!==data || s_axi_rresp!==response)
                $fatal(1,"read mismatch got %h/%b expected %h/%b",s_axi_rdata,s_axi_rresp,data,response);
            @(negedge clk); s_axi_rready=1;
            @(posedge clk); #1;
            @(negedge clk); s_axi_rready=0;
        end
    endtask
    task read_bus(input [11:0] address, input [31:0] data, input [1:0] response);
        begin send_ar(address); take_r(data,response,4); end
    endtask
    task enable_bus;
        begin
            @(negedge clk); resume=1;
            clocks(1); @(negedge clk); resume=0;
            if (quiesced) $fatal(1,"local resume refused after drain");
        end
    endtask
    task new_session;
        begin
            write_bus(32,1,15,2,0); clocks(8);
            read_bus(0,12,0);
            write_bus(32,2,15,2,0); read_bus(0,1,0);
        end
    endtask
    task stage_packet;
        integer j;
        begin
            memory[512]=32'h02003c00; // BE length 60, serial 2 in little-endian AXI word.
            for(j=1;j<16;j=j+1) memory[512+j]=32'h12340000+j;
            write_bus(4,32'hc001,15,0,0);
            write_bus(8,32'h0002003c,15,1,0);
            write_bus(12,1,15,2,0);
        end
    endtask
    task wait_packet;
        begin
            while (!packet_valid) clocks(1);
            if (packet_cookie!=32'hc001 || packet_error) $fatal(1,"packet failed through adapter");
        end
    endtask
    task flush_after_local_drain;
        begin
            if (!local_drained) $fatal(1,"flush before local drain");
            @(negedge clk); flush_request=1;
            clocks(8);
            if (!core_flush_done && !mailbox_halted) $fatal(1,"core not drained");
            if (s_axi_awready || s_axi_wready || s_axi_arready) $fatal(1,"flush reopened adapter");
            @(negedge clk); flush_request=0;
        end
    endtask

`ifdef COMBINED_PACKET_ENGINE
    integer fg_requests=0, fg_responses=0, bg_requests=0, bg_responses=0;
    reg held_ar=0;
    reg [31+8+2+4+3+TEST_ID_WIDTH:0] saved_ar;
    wire [31+8+2+4+3+TEST_ID_WIDTH:0] full_ar={araddr,arlen,arburst,arcache,arprot,arid};
    always @(posedge clk) begin
        if (!aresetn) held_ar<=0;
        else begin
            if (held_ar && (!arvalid || full_ar!==saved_ar))
                $fatal(1,"engine physical AR changed before acceptance");
            held_ar<=arvalid && !arready; saved_ar<=full_ar;
            if (fg_arvalid && fg_arready) fg_requests=fg_requests+1;
            if (engine.bg_arvalid && engine.bg_arready) bg_requests=bg_requests+1;
            if (fg_rvalid && engine.bg_rvalid) $fatal(1,"engine crossed response ownership");
            if (fg_rvalid && fg_rready) begin
                if (fg_rdata!==32'hfe123456 || fg_rid!=1 || fg_rresp!=0 || !fg_rlast)
                    $fatal(1,"engine foreground response corrupted");
                fg_responses=fg_responses+1;
            end
            if (engine.bg_rvalid && engine.bg_rready) begin
                if (engine.bg_rid!==BG_ID) $fatal(1,"engine packet RID corrupted");
                if (engine.bg_rlast) bg_responses=bg_responses+1;
            end
        end
    end
    task foreground_start;
        begin
            @(negedge clk); fg_arvalid=1;
            @(posedge clk); while (!fg_arready) @(posedge clk);
            @(negedge clk); fg_arvalid=0;
        end
    endtask
    task foreground_finish;
        begin
            while (!fg_rvalid) clocks(1);
            @(negedge clk); fg_rready=1;
            @(posedge clk); #1;
            @(negedge clk); fg_rready=0;
        end
    endtask
    task ack_packet;
        begin
            @(negedge clk); ack_valid=1; ack_cookie=32'hc001;
            @(posedge clk); while (!ack_ready) @(posedge clk);
            @(negedge clk); ack_valid=0; clocks(4);
            read_bus(20,32'hc001,0); write_bus(28,32'hc001,15,2,0);
        end
    endtask
    task combined_tests;
        integer old_requests, old_fg, old_flushes;
        reg [31+8+2+4+3+TEST_ID_WIDTH:0] frozen_ar;
        begin
            memory[32768]=32'hfe123456;
            foreground_pending=1; fg_rready=0;
            stage_packet; write_bus(16,32'hc001,15,2,0);
            clocks(10);
            if (!engine.bg_arvalid || arvalid) $fatal(1,"engine foreground reservation lost");
            foreground_start;
            while (!fg_rvalid) clocks(1);
            clocks(20);
            if (packet_valid || engine.bg_arready) $fatal(1,"prefetch bypassed held foreground response");
            foreground_finish;
            @(negedge clk); foreground_pending=0;
            wait_packet;
            old_requests=requests;
            // Read the completed bank while unrelated demand AXI remains stalled.
            allow_r=0; foreground_start;
            @(negedge clk); host_read=1; host_word=15;
            clocks(1);
            if (!host_read_valid || host_data!==memory[527]) $fatal(1,"local bank waited on demand AXI");
            @(negedge clk); host_read=0;
            if (requests!=old_requests+1) $fatal(1,"local bank read issued extra DDR request");
            allow_r=1; foreground_finish; ack_packet;
            $display("PASS engine foreground priority/backpressure and local bank independence");

            // Packet-selected AR cannot be abandoned when the mailbox flushes;
            // a later foreground request must wait for that accepted tail.
            allow_ar=0; allow_r=0;
            stage_packet; write_bus(16,32'hc001,15,2,0);
            while (!arvalid) clocks(1);
            frozen_ar=full_ar; old_fg=fg_requests; old_flushes=flushes;
            @(negedge clk); quiesce_request=1;
            clocks(2); if (!local_drained) $fatal(1,"idle control adapter did not drain");
            @(negedge clk); flush_request=1; fg_arvalid=1;
            clocks(30);
            if (flushes!=old_flushes+1 || !arvalid || full_ar!==frozen_ar || mailbox_halted)
                $fatal(1,"engine logical flush abandoned selected packet AR");
            @(negedge clk); allow_ar=1;
            while (!active) clocks(1);
            clocks(2500); // 25 us delayed response, with a later foreground waiting.
            if (mailbox_halted || fg_requests!=old_fg || packet_valid)
                $fatal(1,"engine released ownership before packet tail drained");
            @(negedge clk); allow_r=1;
            @(posedge clk); while (!fg_arready) @(posedge clk);
            @(negedge clk); fg_arvalid=0;
            while (!fg_rvalid) clocks(1);
            clocks(10);
            if (!mailbox_halted || !local_drained || !fg_rvalid || rready)
                $fatal(1,"packet drain incorrectly claimed or reset physical foreground owner");
            foreground_finish;
            @(negedge clk); flush_request=0; quiesce_request=0;
            enable_bus; write_bus(32,2,15,2,0);
            read_bus(0,1,0);
            $display("PASS engine packet flush retains stalled AR/tail and leaves foreground owner alive");

            // Foreground was selected first. A packet's asserted-but-unselected
            // AR must survive its own flush and drain after foreground finishes.
            allow_ar=0; allow_r=0;
            @(negedge clk); fg_arvalid=1;
            while (!arvalid) clocks(1);
            frozen_ar=full_ar;
            stage_packet; write_bus(16,32'hc001,15,2,0);
            while (!engine.bg_arvalid) clocks(1);
            @(negedge clk); quiesce_request=1;
            clocks(2);
            @(negedge clk); flush_request=1;
            clocks(30);
            if (!arvalid || full_ar!==frozen_ar || !engine.bg_arvalid || mailbox_halted)
                $fatal(1,"packet reset damaged queued physical ownership");
            @(negedge clk); allow_ar=1;
            @(posedge clk); while (!fg_arready) @(posedge clk);
            @(negedge clk); fg_arvalid=0; allow_r=1;
            while (!fg_rvalid) clocks(1);
            clocks(20); if (mailbox_halted) $fatal(1,"unselected packet request discarded on flush");
            foreground_finish;
            while (!mailbox_halted) clocks(1);
            if (packet_valid) $fatal(1,"discarded packet became visible");
            @(negedge clk); flush_request=0; quiesce_request=0;
            enable_bus; write_bus(32,2,15,2,0);
            stage_packet; write_bus(16,32'hc001,15,2,0); wait_packet; ack_packet;
            if (fg_requests!=fg_responses || bg_requests!=bg_responses || active || arvalid || rvalid)
                $fatal(1,"engine transactions unbalanced after combined drain");
            $display("PASS engine foreground-held reset, queued packet drain and fresh-session recovery");
            $display("PASS engine integration groups=3 fg=%0d/%0d packet=%0d/%0d",fg_requests,fg_responses,bg_requests,bg_responses);
        end
    endtask
`endif

    integer before_count, before_accepts, before_aw;
    initial begin #1000000; $fatal(1,"AXI-Lite test timed out"); end
    initial begin
        clocks(3); @(negedge clk); aresetn=1; clocks(2);
        if (!local_drained || !quiesced) $fatal(1,"fabric startup was not fenced");
        enable_bus; new_session;
        stage_packet;
        read_bus(4,32'hc001,0); read_bus(8,32'h0002003c,0); read_bus(12,1,0);
        write_bus(4,32'hdead,3,0,0); // logical rejection is OKAY + LAST_RESULT.
        read_bus(36,32'h111,0); read_bus(4,32'hc001,0);
        write_bus(12'h104,32'hdead,15,1,2); // Must not alias shadow word 1.
        write_bus(5,32'hdead,15,2,2); write_bus(40,32'hdead,15,0,2);
        read_bus(12'h104,0,2); read_bus(5,0,2); read_bus(40,0,2);
        read_bus(36,32'h111,0); read_bus(4,32'hc001,0);
        $display("PASS independent AW/W, captured fields, held B, logical rejection and address validation");

        // Hold LAST_RESULT read while a real COMMIT changes it underneath.
        send_ar(36);
        before_count=strobes; before_accepts=accepts;
        fork send_aw(16); send_w(32'hc001,15); join
        while (!s_axi_bvalid) clocks(1);
        clocks(50); wait_packet;
        if (strobes!=before_count+1 || accepts!=before_accepts+1)
            $fatal(1,"COMMIT repeated during B stall");
        before_aw=aw_count;
        // Offer further requests while both responses are held; none may
        // overwrite the first request or response. VALID stays high until READY.
        @(negedge clk); s_axi_awvalid=1; s_axi_wvalid=1; s_axi_arvalid=1;
        s_axi_awaddr=12'h104; s_axi_wdata=32'hdead; s_axi_wstrb=15; s_axi_araddr=36;
        clocks(15);
        if (s_axi_awready || s_axi_wready || s_axi_arready || strobes!=before_count+1 || aw_count!=before_aw)
            $fatal(1,"new request admitted over stalled response");
        take_r(32'h111,0,10);
        @(posedge clk); if (!s_axi_arready) $fatal(1,"second read did not progress");
        @(negedge clk); s_axi_arvalid=0;
        take_r(32'h140,0,10); take_b(0,20);
        @(posedge clk);
        if (!s_axi_awready || !s_axi_wready) $fatal(1,"second write did not progress");
        @(negedge clk); s_axi_awvalid=0; s_axi_wvalid=0;
        take_b(2,10);
        if (strobes!=before_count+1 || accepts!=before_accepts+1)
            $fatal(1,"stalled following request duplicated COMMIT");
        read_bus(36,32'h140,0);
        @(negedge clk); host_read=1; host_word=15;
        clocks(1); if (!host_read_valid || host_data!==memory[527]) $fatal(1,"payload mismatch");
        @(negedge clk); host_read=0; ack_valid=1; ack_cookie=32'hc001;
        @(posedge clk); while (!ack_ready) @(posedge clk);
        @(negedge clk); ack_valid=0; clocks(4);
        read_bus(20,32'hc001,0); read_bus(24,1,0);
        write_bus(28,32'hc001,15,1,0); read_bus(20,0,0);
        $display("PASS independent read/write progress, frozen R snapshot, exact COMMIT/POP and real payload");

        // Missing W must be accepted after quiesce. Resume cannot drop AW/R/B.
        send_ar(4); send_aw(4);
        @(negedge clk); quiesce_request=1; resume=1;
        clocks(30);
        if (local_drained || s_axi_awready || !s_axi_wready || s_axi_arready)
            $fatal(1,"quiesce lost AW-only ownership");
        send_w(32'hc002,15); clocks(4);
        @(negedge clk); quiesce_request=0; // Latched until valid resume after drain.
        clocks(15);
        if (local_drained || !quiesced || s_axi_awready || s_axi_wready || s_axi_arready)
            $fatal(1,"early resume while responses outstanding");
        take_b(0,20); if (local_drained) $fatal(1,"R ignored by drain");
        @(negedge clk); resume=0;
        take_r(32'hc001,0,20); clocks(1);
        if (!local_drained) $fatal(1,"AW-only transaction never drained");
        flush_after_local_drain; enable_bus;
        read_bus(4,32'hc002,0); // Old write completed normally before flush.
        write_bus(32,2,15,2,0); read_bus(0,1,0);
        $display("PASS AW-only quiesce, response drain, early resume rejection and ordered mailbox flush");

        send_w(32'hc003,15);
        @(negedge clk); quiesce_request=1;
        clocks(30);
        if (local_drained || !s_axi_awready || s_axi_wready || s_axi_arready)
            $fatal(1,"quiesce lost W-only ownership");
        send_aw(4); take_b(0,30); clocks(2);
        if (!local_drained) $fatal(1,"W-only transaction never drained");
        // Held request beats resume; no auto-rearm when it later falls.
        @(negedge clk); resume=1; clocks(3);
        if (!quiesced) $fatal(1,"resume overrode active quiesce");
        @(negedge clk); resume=0; quiesce_request=0;
        clocks(3); if (!local_drained) $fatal(1,"quiesce fell without explicit resume");
        flush_after_local_drain; enable_bus; write_bus(32,2,15,2,0);
        read_bus(4,32'hc003,0);
        // Request arriving together with quiesce must remain unaccepted.
        @(negedge clk); quiesce_request=1; s_axi_awvalid=1; s_axi_wvalid=1;
        s_axi_arvalid=1; s_axi_awaddr=4; s_axi_wdata=32'hc004; s_axi_wstrb=15; s_axi_araddr=4;
        clocks(10);
        if (!local_drained || s_axi_bvalid || s_axi_rvalid) $fatal(1,"new traffic admitted during quiesce");
        @(negedge clk); quiesce_request=0;
        enable_bus;
        @(posedge clk); #1;
        @(negedge clk); s_axi_awvalid=0; s_axi_wvalid=0; s_axi_arvalid=0;
        take_r(32'hc003,0,4); take_b(0,4); read_bus(4,32'hc004,0);
        // The retained VALID above is deliberately an *unaccepted* request:
        // local_drained cannot identify an old upstream request. External fence required.
        $display("PASS W-only quiesce, held-level priority and explicit upstream-fence boundary");

        // Same-edge read/CSR update returns pre-write data.
        send_w(32'hc005,15); send_aw(4);
        s_axi_araddr=4; s_axi_arvalid=1; // send_aw returns on negedge before write edge.
        @(posedge clk); if (!s_axi_arready) $fatal(1,"read unexpectedly blocked by write");
        @(negedge clk); s_axi_arvalid=0;
        take_r(32'hc004,0,5); take_b(0,5); read_bus(4,32'hc005,0);
        if (aw_count!=b_count || w_count!=b_count || ar_count!=r_count)
            $fatal(1,"unbalanced AXI transactions before fabric reset");
        // Common fabric reset may cancel ownership, unlike logical quiesce.
        send_aw(4);
        @(negedge clk); aresetn=0; clocks(3);
        @(negedge clk); aresetn=1; clocks(3);
        if (!local_drained || s_axi_bvalid || s_axi_rvalid) $fatal(1,"fabric reset retained old request");
        enable_bus; new_session;
        write_bus(4,32'hbeef,15,1,0); read_bus(4,32'hbeef,0);
        send_ar(4); fork send_aw(4); send_w(32'hbeef1,15); join
        while (!s_axi_bvalid) clocks(1);
        @(negedge clk); aresetn=0; clocks(3);
        @(negedge clk); aresetn=1; clocks(3);
        if (!local_drained || s_axi_bvalid || s_axi_rvalid) $fatal(1,"fabric reset retained old response");
        enable_bus; new_session; read_bus(4,0,0);
        if (aw_count!=b_count || w_count!=b_count || ar_count!=r_count)
            $fatal(1,"unbalanced final AXI transactions");
        $display("PASS concurrent read-before-write and common fabric reset of requests/responses");
`ifdef COMBINED_PACKET_ENGINE
        combined_tests;
`endif
        $display("PASS AXI-Lite groups=5 CSR strobes=%0d core accepts=%0d releases=%0d DDR requests=%0d",strobes,accepts,releases,requests);
        $finish;
    end
endmodule
