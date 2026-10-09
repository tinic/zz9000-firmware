// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
module mailbox_tb;
    localparam BASE = 32'h3fe00000;
    reg clk = 0;
    always #5 clk = !clk;
    reg aresetn = 0, csr_write = 0, flush_request = 0;
    reg [3:0] csr_word = 0, csr_wstrb = 15, csr_read_word = 0;
    reg [31:0] csr_wdata = 0;
    wire csr_error;
    wire [31:0] csr_rdata;
    wire core_flush, core_flush_done, desc_valid, desc_ready;
    wire [6:0] desc_slot, release_slot;
    wire [11:0] desc_length;
    wire [15:0] desc_serial;
    wire [31:0] desc_cookie, release_cookie;
    wire [1:0] desc_csum;
    wire release_valid, release_ready, release_error;
    zz_eth_packet_mailbox mailbox (.*);

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
    zz_eth_packet_window core (.flush(core_flush), .flush_done(core_flush_done), .*);

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
            end
            if (active && !rvalid && allow_r) begin
                rdata <= memory[word_index]; rresp <= 0; rlast <= beats == 1; rvalid <= 1;
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
    task write_csr(input [3:0] word, input [31:0] data, input [3:0] mask, input integer rejected);
        begin
            @(negedge clk); csr_word = word; csr_wdata = data; csr_wstrb = mask; csr_write = 1;
            #1;
            if (csr_error !== (rejected != 0))
                $fatal(1, "CSR result word=%d data=%h got error=%b expected=%d", word, data, csr_error, rejected);
            @(posedge clk); #1; csr_read_word = 9; #1;
            if (csr_rdata !== (32'h100 | (word << 4) | rejected))
                $fatal(1, "LAST_RESULT lost write outcome");
            @(negedge clk); csr_write = 0;
        end
    endtask
    task status_wait(input [31:0] mask, input [31:0] expected);
        integer n;
        begin
            csr_read_word = 0; #1; n = 0;
            while ((csr_rdata & mask) != expected && n < 12000) begin clocks(1); n=n+1; end
            if ((csr_rdata & mask) != expected) $fatal(1, "status timeout %h expected %h/%h", csr_rdata, expected, mask);
        end
    endtask
    task start_session;
        begin
            write_csr(8, 1, 15, 0); status_wait(15, 12);
            write_csr(8, 2, 15, 0); status_wait(15, 1);
        end
    endtask
    task stage(input integer slot, input integer length, input integer serial, input [31:0] cookie);
        integer w;
        begin
            memory[slot*512] = ((length>>8)&255) | ((length&255)<<8) |
                              (((serial>>8)&255)<<16) | ((serial&255)<<24);
            for (w=1; w<((length+7)/4); w=w+1) memory[slot*512+w] = cookie ^ (32'h12340000+w);
            write_csr(1, cookie, 15, 0);
            write_csr(2, (serial<<16)|length, 15, 0);
            write_csr(3, (3<<7)|slot, 15, 0);
        end
    endtask
    task packet(input [31:0] cookie, input integer error);
        integer n;
        begin
            n=0;
            while ((!packet_valid || packet_cookie != cookie) && n<12000) begin clocks(1); n=n+1; end
            if (!packet_valid || packet_cookie != cookie || packet_error !== (error!=0))
                $fatal(1, "packet mismatch wanted %h error %d got %h/%b", cookie,error,packet_cookie,packet_error);
        end
    endtask
    task read_word(input integer word, input [31:0] expected);
        begin
            @(negedge clk); host_word=word; host_read=1;
            @(posedge clk); #1;
            if (!host_read_valid || host_data !== expected) $fatal(1, "packet data mismatch");
            @(negedge clk); host_read=0;
        end
    endtask
    task ack(input [31:0] cookie);
        integer n;
        begin
            @(negedge clk); ack_cookie=cookie; #1; n=0;
            while (!ack_ready && n<12000) begin clocks(1); n=n+1; end
            if (!ack_ready) $fatal(1, "ACK blocked");
            @(negedge clk); ack_valid=1;
            @(posedge clk); #1;
            @(negedge clk); ack_valid=0;
        end
    endtask
    task release_snapshot(input [31:0] cookie, input integer slot, input integer error);
        begin
            status_wait(32,32);
            csr_read_word=5; #1; if (csr_rdata !== cookie) $fatal(1, "release cookie mismatch");
            clocks(4); if (csr_rdata !== cookie) $fatal(1, "release snapshot changed without POP");
            csr_read_word=6; #1; if (csr_rdata !== ((error<<7)|slot)) $fatal(1, "release metadata mismatch");
        end
    endtask

    integer saved_requests, saved_accepts, saved_flushes;
    reg [31:0] saved_ar;
    initial begin
        #10000000; $fatal(1, "mailbox test timed out");
    end
    initial begin
        clocks(3); @(negedge clk); aresetn=1; clocks(2);
        write_csr(8,2,15,1); write_csr(1,32'h1001,15,1);
        start_session;
        write_csr(1,32'h1001,3,1); write_csr(1,32'h1001,15,0);
        write_csr(4,32'h1001,15,1); // missing fields
        stage(0,60,2,0); write_csr(4,0,15,1); // zero cookie is never published
        stage(1,60,2,32'h1001);
        write_csr(1,32'hdeadbeef,3,1); csr_read_word=1; #1;
        if (csr_rdata !== 32'h1001) $fatal(1, "partial write changed shadow data");
        write_csr(2,32'h0002103c,15,0); write_csr(4,32'h1001,15,1); // reserved length bits
        write_csr(2,32'h0002003c,15,0);
        write_csr(3,32'h00000381,15,0); write_csr(4,32'h1001,15,1); // reserved slot bits
        write_csr(3,32'h00000181,15,0); write_csr(4,32'hdead,15,1);
        write_csr(4,32'h1001,15,0); packet(32'h1001,0);
        write_csr(4,32'h1001,15,1); // no fresh staging, even after queue drains
        read_word(0,memory[512]); read_word(15,memory[527]);
        if (accepts != 1 || accepted_cookie[0] != 32'h1001) $fatal(1, "COMMIT not exactly once");
        $display("PASS atomic staging, partial/reserved-field rejection, result readback and exact-once COMMIT");

        stage(2,60,3,32'h1002); write_csr(4,32'h1002,15,0); clocks(70);
        stage(3,60,4,32'h1003); write_csr(4,32'h1003,15,0); status_wait(16,16);
        stage(4,13,5,32'h1004); write_csr(4,32'h1004,15,1); // busy queue, retain staging
        clocks(8);
        if (accepts != 2 || desc_cookie != 32'h1003) $fatal(1, "busy COMMIT overwrote queue");
        ack(32'h1001); release_snapshot(32'h1001,1,0);
        packet(32'h1002,0); ack(32'h1002);
        packet(32'h1003,0); @(negedge clk); ack_cookie=32'h1003; #1;
        if (ack_ready) $fatal(1, "release backpressure lost");
        write_csr(7,32'hbad,15,1); release_snapshot(32'h1001,1,0);
        write_csr(7,32'h1001,15,0); ack(32'h1003);
        release_snapshot(32'h1002,2,0); write_csr(7,32'h1001,15,1);
        write_csr(7,32'h1002,15,0); release_snapshot(32'h1003,3,0);
        write_csr(7,32'h1003,15,0); write_csr(7,32'h1003,15,1);
        saved_requests=requests;
        write_csr(4,32'h1004,15,0); packet(32'h1004,1); ack(32'h1004);
        release_snapshot(32'h1004,4,1); // hold this record across the following flush
        if (requests != saved_requests || accepts != 4 || releases != 4)
            $fatal(1, "error release or acceptance count mismatch");
        $display("PASS stable queued descriptor, busy retry, held release snapshot, exact POP and backpressure");

        allow_ar=0; allow_r=0;
        stage(5,60,6,32'h1005); write_csr(4,32'h1005,15,0);
        while (!arvalid) clocks(1);
        stage(6,60,7,32'h1006); write_csr(4,32'h1006,15,0); clocks(3);
        stage(7,60,8,32'h1007); write_csr(4,32'h1007,15,0); status_wait(16,16);
        saved_ar=araddr; saved_accepts=accepts; saved_flushes=flushes;
        @(negedge clk); flush_request=1; csr_write=1; csr_word=1; csr_wdata=32'hbad; #1;
        if (!csr_error || !core_flush || desc_valid) $fatal(1, "flush did not win concurrent write");
        @(posedge clk); #1; @(negedge clk); csr_write=0;
        clocks(8); csr_read_word=0; #1;
        if (flushes != saved_flushes+1 || !arvalid || araddr != saved_ar || (csr_rdata&15)!=2 ||
            (csr_rdata&48)!=48)
            $fatal(1, "flush cancelled stalled AR or rearmed early");
        write_csr(8,2,15,1); write_csr(4,32'h1007,15,1);
        allow_ar=1; while (!active) clocks(1);
        clocks(2500); csr_read_word=0; #1;
        if ((csr_rdata&15)!=2 || (csr_rdata&48)!=48 || accepts != saved_accepts || packet_valid)
            $fatal(1, "retired ownership before delayed tail drained");
        allow_r=1; status_wait(15,12);
        if (arvalid || active || (csr_rdata&48)!=0) $fatal(1, "HALTED while AXI or mailbox still owned");
        write_csr(8,2,15,1); // external request is still high
        @(negedge clk); flush_request=0; clocks(3);
        write_csr(8,2,15,0); write_csr(4,32'h1007,15,1); // stale staging invalidated
        stage(5,60,9,32'h2005); write_csr(4,32'h2005,15,0);
        packet(32'h2005,0); ack(32'h2005); release_snapshot(32'h2005,5,0); write_csr(7,32'h2005,15,0);
        $display("PASS flush beats writes, one pulse for held request, stalled AR/25us drain, HALTED and explicit rearm");

        allow_r=0; stage(8,60,10,32'h2008); write_csr(4,32'h2008,15,0);
        while (!active) clocks(1);
        @(negedge clk); aresetn=0; clocks(3);
        @(negedge clk); aresetn=1; allow_r=1; clocks(3);
        if (arvalid || release_valid || packet_valid || desc_valid) $fatal(1, "fabric reset leaked old work");
        csr_read_word=9; #1; if (csr_rdata != 0) $fatal(1, "fabric reset kept stale result");
        write_csr(8,2,15,1); start_session;
        stage(8,60,11,32'h3008); write_csr(4,32'h3008,15,0); packet(32'h3008,0);
        read_word(1,memory[4097]); ack(32'h3008); release_snapshot(32'h3008,8,0);
        write_csr(7,32'h3008,15,0);
        if (commits!=10 || accepts!=9 || releases!=6 || requests!=7)
            $fatal(1, "final transaction count mismatch");
        $display("PASS shared fabric reset mid-burst and fresh-session data");
        $display("ALL PASS mailbox: commits=%0d accepts=%0d releases=%0d requests=%0d",commits,accepts,releases,requests);
        $finish;
    end
endmodule
