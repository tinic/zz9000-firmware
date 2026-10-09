// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
module packet_window_tb;
    localparam BASE = 32'h3fe00000;
    reg clk = 0;
    always #5 clk = !clk;
    reg aresetn = 0, flush = 0;
    wire flush_done;
    reg desc_valid = 0;
    wire desc_ready;
    reg [6:0] desc_slot = 0;
    reg [11:0] desc_length = 0;
    reg [15:0] desc_serial = 0;
    reg [31:0] desc_cookie = 0;
    reg [1:0] desc_csum = 0;
    wire packet_valid, packet_error;
    wire [11:0] packet_length;
    wire [15:0] packet_serial;
    wire [31:0] packet_cookie;
    wire [1:0] packet_csum;
    reg host_read = 0;
    reg [8:0] host_word = 0;
    wire host_read_valid;
    wire [31:0] host_data;
    reg ack_valid = 0;
    reg [31:0] ack_cookie = 0;
    wire ack_ready;
    wire release_valid, release_error;
    reg release_ready = 1;
    wire [6:0] release_slot;
    wire [31:0] release_cookie;
    wire [31:0] araddr;
    wire [7:0] arlen;
    wire [2:0] arsize;
    wire [1:0] arburst;
    wire arvalid, arready, rready;
    reg [31:0] rdata = 0;
    reg [1:0] rresp = 0;
    reg rlast = 0, rvalid = 0;

    wire [31:0] core_araddr, core_rdata;
    wire [7:0] core_arlen;
    wire [2:0] core_arsize;
    wire [1:0] core_arburst, core_rresp;
    wire core_arvalid, core_arready, core_rlast, core_rvalid, core_rready;
    zz_eth_packet_window dut (
        .araddr(core_araddr), .arlen(core_arlen), .arsize(core_arsize),
        .arburst(core_arburst), .arvalid(core_arvalid), .arready(core_arready),
        .rdata(core_rdata), .rresp(core_rresp), .rlast(core_rlast),
        .rvalid(core_rvalid), .rready(core_rready), .*
    );
`ifdef SHARED_READ_PORT
    reg foreground_pending = 0;
    reg [31:0] fg_araddr = 0;
    reg [7:0] fg_arlen = 0;
    reg [1:0] fg_arburst = 1;
    reg fg_arvalid = 0, fg_rready = 1;
    wire fg_arready, fg_rlast, fg_rvalid;
    wire [31:0] fg_rdata;
    wire [1:0] fg_rresp;
    zz_eth_read_arbiter arbiter (
        .bg_araddr(core_araddr), .bg_arlen(core_arlen), .bg_arburst(core_arburst),
        .bg_arvalid(core_arvalid), .bg_arready(core_arready),
        .bg_rdata(core_rdata), .bg_rresp(core_rresp), .bg_rlast(core_rlast),
        .bg_rvalid(core_rvalid), .bg_rready(core_rready), .*
    );
`else
    assign araddr = core_araddr;
    assign arlen = core_arlen;
    assign arsize = core_arsize;
    assign arburst = core_arburst;
    assign arvalid = core_arvalid;
    assign core_arready = arready;
    assign core_rdata = rdata;
    assign core_rresp = rresp;
    assign core_rlast = rlast;
    assign core_rvalid = rvalid;
    assign rready = core_rready;
`endif

    reg [31:0] memory [0:65535];
    reg allow_ar = 1, allow_r = 1, jitter = 0;
    reg pending = 0;
    integer bus_word = 0, bus_left = 0, latency = 0;
    integer error_word = -1;
    // -1 early LAST, +1 late LAST, 0 well-formed; consumed per request.
    integer malformed = 0;
    reg [31:0] rng = 32'h519f02b7;
    integer requests = 0, responses = 0, releases = 0;
    reg [31:0] address_log [0:4095];
    reg stalled_ar = 0;
    reg [31:0] stalled_addr;
    reg [7:0] stalled_len;
    assign arready = allow_ar && !pending && (!jitter || rng[0]);

    // Independent AXI slave: requests produce immutable memory data, with
    // delayed ARREADY and gapped RVALID. Response VALID stays until accepted.
    always @(posedge clk) begin
        rng <= {rng[30:0], rng[31] ^ rng[21] ^ rng[1] ^ rng[0]};
        if (!aresetn) begin
            pending <= 0;
            rvalid <= 0;
            rlast <= 0;
            stalled_ar <= 0;
        end else begin
            if (stalled_ar && (!arvalid || araddr !== stalled_addr || arlen !== stalled_len))
                $fatal(1, "AR changed before handshake");
            stalled_ar <= arvalid && !arready;
            stalled_addr <= araddr;
            stalled_len <= arlen;
            if (arvalid && arready) begin
                if (pending || arsize != 2 || arburst != 1 || arlen > 15 ||
                    araddr < BASE || araddr >= BASE + 32'h40000 ||
                    {1'b0, araddr[11:0]} + (arlen + 1) * 4 > 4096)
                    $fatal(1, "Invalid AXI request %h len %d", araddr, arlen);
                pending <= 1;
                bus_word <= (araddr - BASE) >> 2;
                bus_left <= arlen + 1 + malformed;
                malformed <= 0;
                latency <= 3;
                address_log[requests] <= araddr;
                requests <= requests + 1;
            end
            if (pending && !rvalid && allow_r && (!jitter || rng[3])) begin
                if (latency != 0) latency <= latency - 1;
                else begin
                    rdata <= memory[bus_word];
                    rresp <= bus_word == error_word ? 2'b10 : 2'b00;
                    rlast <= bus_left == 1;
                    rvalid <= 1;
                end
            end
            if (rvalid && rready) begin
                responses <= responses + 1;
                rvalid <= 0;
                bus_word <= bus_word + 1;
                bus_left <= bus_left - 1;
                if (rlast) pending <= 0;
            end
            if (release_valid && release_ready) releases <= releases + 1;
            if (host_read_valid && (^host_data === 1'bx)) $fatal(1, "Uninitialized host data");
        end
    end

    task clocks(input integer count);
        repeat (count) begin @(posedge clk); #1; end
    endtask

    task reset_fabric;
        begin
            @(negedge clk); aresetn = 0;
`ifdef SHARED_READ_PORT
            // Fabric reset must reset all clients as well as the shared port.
            fg_arvalid = 0; foreground_pending = 0; fg_rready = 1;
`endif
            clocks(3);
            @(negedge clk); aresetn = 1;
            clocks(2);
            if (arvalid || packet_valid || release_valid) $fatal(1, "Dirty reset");
        end
    endtask

    task put_packet(input integer s, input integer len, input integer seq, input integer ticket);
        integer w;
        begin
            for (w = 0; w < 512; w = w + 1)
                memory[s * 512 + w] = 32'h93a50000 ^ (ticket * 65537) ^ (w * 32'h1010101);
            memory[s * 512] = {seq[7:0], seq[15:8], len[7:0], len[15:8]};
        end
    endtask

    task submit(input integer s, input integer len, input integer seq, input integer ticket);
        integer waited;
        begin
            @(negedge clk);
            desc_slot = s; desc_length = len; desc_serial = seq;
            desc_cookie = ticket; desc_csum = ticket & 3; desc_valid = 1;
            @(posedge clk);
            waited = 0;
            while (!desc_ready && waited < 12000) begin @(posedge clk); waited = waited + 1; end
            if (!desc_ready) $fatal(1, "Descriptor %d timed out", ticket);
            @(negedge clk); desc_valid = 0;
        end
    endtask

    task await_packet(input integer ticket, input integer err);
        integer cycles;
        begin
            cycles = 0;
            while (!packet_valid && cycles < 12000) begin clocks(1); cycles = cycles + 1; end
            if (!packet_valid || packet_cookie !== ticket || packet_error !== (err != 0))
                $fatal(1, "Packet ticket=%d err=%d got valid=%b ticket=%d err=%b",
                       ticket, err, packet_valid, packet_cookie, packet_error);
        end
    endtask

    task read_word(input integer s, input integer w, input integer valid);
        begin
            @(negedge clk); host_read = 1; host_word = w;
            @(posedge clk); #1;
            if (host_read_valid !== (valid != 0)) $fatal(1, "Read validity word %d", w);
            if (valid && host_data !== memory[s * 512 + w])
                $fatal(1, "Read s=%d w=%d got=%h want=%h", s, w, host_data, memory[s*512+w]);
            @(negedge clk); host_read = 0;
        end
    endtask

    task verify_packet(input integer s, input integer len, input integer seq, input integer ticket);
        integer w;
        begin
            await_packet(ticket, 0);
            if (packet_length != len || packet_serial != seq || packet_csum != (ticket & 3))
                $fatal(1, "Packet metadata mismatch");
            // Out-of-order and repeated reads, then a full payload comparison.
            read_word(s, 7, 1);
            read_word(s, 0, 1);
            read_word(s, 7, 1);
            for (w = 0; w < (len + 7) / 4; w = w + 1) read_word(s, w, 1);
            if (len < 2044) read_word(s, (len + 7) / 4, 0);
            // Another queued packet may legitimately be prefetched during this.
        end
    endtask

    task ack(input integer ticket, input integer s, input integer err);
        integer waited;
        begin
            @(negedge clk); ack_cookie = ticket; ack_valid = 1;
            @(posedge clk);
            waited = 0;
            while (!ack_ready && waited < 12000) begin @(posedge clk); waited = waited + 1; end
            if (!ack_ready) $fatal(1, "ACK %d timed out; release=%b/%d packet=%b/%d",
                                   ticket, release_valid, release_cookie, packet_valid, packet_cookie);
            #1;
            if (!release_valid || release_cookie !== ticket || release_slot != s ||
                release_error !== (err != 0)) $fatal(1, "Release mismatch");
            @(negedge clk); ack_valid = 0;
        end
    endtask

    task do_flush;
        begin
            @(negedge clk); flush = 1;
            @(negedge clk); flush = 0;
        end
    endtask

    task await_flush;
        integer cycles;
        begin
            cycles = 0;
            while (!flush_done && cycles < 12000) begin clocks(1); cycles = cycles + 1; end
            // In shared mode a foreground transaction may start as soon as
            // this client's discarded tail drains; flush need not idle it.
            if (!flush_done || packet_valid || release_valid || core_arvalid || core_rvalid)
                $fatal(1, "Incomplete flush");
`ifndef SHARED_READ_PORT
            if (arvalid || pending) $fatal(1, "Physical port still owned after flush");
`endif
        end
    endtask

`ifdef SHARED_READ_PORT
    // Foreground AXI client with independently checked data and response order.
    task demand_read(input integer word_index, input integer count, input integer stall);
        integer w, waited;
        begin
            @(negedge clk);
            foreground_pending = 1; fg_arvalid = 1;
            fg_araddr = BASE + word_index * 4; fg_arlen = count - 1;
            fg_rready = stall == 0;
            @(posedge clk);
            waited = 0;
            while (!fg_arready && waited < 12000) begin @(posedge clk); waited = waited + 1; end
            if (!fg_arready) $fatal(1, "Foreground address starved");
            @(negedge clk); fg_arvalid = 0;
            if (stall != 0) begin
                clocks(stall);
                if (!fg_rvalid || !pending || core_rvalid)
                    $fatal(1, "Foreground response backpressure lost ownership");
                @(negedge clk); fg_rready = 1;
            end
            for (w = 0; w < count; w = w + 1) begin
                @(posedge clk);
                waited = 0;
                while (!fg_rvalid && waited < 12000) begin @(posedge clk); waited = waited + 1; end
                if (!fg_rvalid || fg_rdata !== memory[word_index + w] || fg_rresp != 0 ||
                    fg_rlast !== (w == count - 1) || core_rvalid)
                    $fatal(1, "Foreground response mixed with prefetch or wrong data");
            end
            @(negedge clk); foreground_pending = 0;
        end
    endtask

    integer first_request;
    task shared_port_tests;
        begin
            put_packet(127, 60, 100, 900);
            put_packet(20, 1514, 101, 901);
            foreground_pending = 1;
            first_request = requests;
            submit(20, 1514, 101, 901);
            while (!core_arvalid) clocks(1);
            clocks(12);
            if (arvalid || requests != first_request)
                $fatal(1, "Prefetch bypassed pending demand");
            demand_read(127*512, 4, 20);
            if (requests != first_request+1 || address_log[first_request] != BASE + 127*2048)
                $fatal(1, "Foreground did not win arbitration");
            verify_packet(20, 1514, 101, 901); ack(901, 20, 0);
            $display("PASS shared port: pending demand priority and response backpressure");

            put_packet(21, 1514, 102, 902);
            allow_r = 0;
            submit(21, 1514, 102, 902);
            while (!pending) clocks(1);
            first_request = requests;
            fork
                demand_read(127*512 + 8, 1, 0);
                begin
                    clocks(12);
                    if (requests != first_request || fg_arready || fg_rvalid)
                        $fatal(1, "Foreground stole an outstanding background burst");
                    @(negedge clk); allow_r = 1;
                end
            join
            if (address_log[first_request] != BASE + 127*2048 + 32)
                $fatal(1, "Foreground waited behind another prefetch burst");
            verify_packet(21, 1514, 102, 902); ack(902, 21, 0);
            $display("PASS shared port: late demand waits one existing burst, then wins");

            put_packet(22, 1514, 103, 903);
            allow_ar = 0; allow_r = 0;
            submit(22, 1514, 103, 903);
            while (!arvalid) clocks(1);
            first_request = requests;
            fork
                demand_read(127*512 + 9, 1, 0);
                begin
                    do_flush(); clocks(10);
                    if (!arvalid || fg_arready || flush_done)
                        $fatal(1, "Flush/foreground cancelled stalled background AR");
                    @(negedge clk); allow_ar = 1;
                    clocks(2500);
                    if (requests != first_request+1 || flush_done || fg_arready || fg_rvalid)
                        $fatal(1, "Reused shared port before delayed background tail");
                    @(negedge clk); allow_r = 1;
                    await_flush();
                end
            join
            if (address_log[first_request+1] != BASE + 127*2048 + 36 || packet_valid)
                $fatal(1, "Flush leaked packet or misrouted next demand");
            $display("PASS shared port: stalled AR and 25 us discarded tail before demand");

            // A bank-window wait must not assert foreground_pending: that would
            // block the very prefetch needed to answer this host read.
            put_packet(23, 61, 104, 904);
            @(negedge clk); host_read = 1; host_word = 0;
            submit(23, 61, 104, 904);
            await_packet(904, 0); clocks(1);
            if (!host_read_valid || host_data !== memory[23*512])
                $fatal(1, "Bank-window wait starved its own prefetch");
            @(negedge clk); host_read = 0;
            verify_packet(23, 61, 104, 904); ack(904, 23, 0);

            // Reset both port and clients while background is outstanding and
            // a foreground request is waiting. Neither may leak into the next epoch.
            put_packet(24, 1514, 105, 905);
            allow_r = 0;
            submit(24, 1514, 105, 905);
            while (!pending) clocks(1);
            @(negedge clk); foreground_pending = 1; fg_arvalid = 1;
            fg_araddr = BASE + 127*2048; fg_arlen = 0;
            clocks(3); reset_fabric(); allow_r = 1;
            demand_read(127*512 + 10, 1, 0);
            if (packet_valid || core_rvalid) $fatal(1, "Pre-reset data leaked");
            clocks(3);
            $display("PASS shared port: bank-window wait and pending demand across fabric reset");
        end
    endtask
`endif

    integer n, before_requests, start_responses, release_offset;
    initial begin
        // Global watchdog catches all task-level waits too.
        #10000000; $fatal(1, "Test timed out");
    end
    initial begin
        reset_fabric();
`ifdef SHARED_READ_PORT
        shared_port_tests();
`endif
        release_offset = releases;
        read_word(0, 0, 0);
        put_packet(0, 1514, 2, 100);
        put_packet(1, 2044, 3, 101);
        start_responses = responses;
        submit(0, 1514, 2, 100);
        submit(1, 2044, 3, 101);
        // Do not ACK the first packet while both banks fill.
        while (responses - start_responses < (1514 + 7) / 4 + 512) clocks(1);
        clocks(3);
        if (desc_ready) $fatal(1, "Overwrote two owned banks");
        before_requests = requests;
        verify_packet(0, 1514, 2, 100);
        ack(100, 0, 0);
        // Second packet must already be visible without another DDR request.
        if (!packet_valid || packet_cookie != 101 || requests != before_requests)
            $fatal(1, "No overlap: second packet was not prefetched");
        verify_packet(1, 2044, 3, 101);
        if (requests != before_requests) $fatal(1, "Host reads issued DDR requests");
        @(negedge clk); ack_cookie = 100; ack_valid = 1;
        clocks(3);
        if (ack_ready || !packet_valid || packet_cookie != 101) $fatal(1, "Duplicate ACK consumed packet");
        @(negedge clk); ack_valid = 0;
        ack(101, 1, 0);
        $display("PASS overlap, max frame, rereads, bounds, duplicate ACK, no DDR on host reads");

        jitter = 1;
        for (n = 0; n < 24; n = n + 1) begin
            // Cross ring wrap and reuse banks/slots with distinct packet data.
            put_packet((126+n) % 128, 60 + n * 59, 16'hffe8+n, 200+n);
            submit((126+n) % 128, 60+n*59, 16'hffe8+n, 200+n);
            verify_packet((126+n) % 128, 60+n*59, 16'hffe8+n, 200+n);
            ack(200+n, (126+n) % 128, 0);
        end
        put_packet(22, 61, 2, 224);
        submit(22, 61, 2, 224);
        verify_packet(22, 61, 2, 224); ack(224, 22, 0);
        jitter = 0;
        $display("PASS gapped responses, delayed READY, ring/serial wrap, partial last word");

        clocks(2); // Retire the preceding test's final release first.
        release_ready = 0;
        put_packet(3, 60, 30, 300); put_packet(4, 60, 31, 301);
        submit(3, 60, 30, 300); submit(4, 60, 31, 301);
        await_packet(300, 0); ack(300, 3, 0);
        await_packet(301, 0);
        @(negedge clk); ack_cookie = 301; ack_valid = 1;
        clocks(10);
        if (ack_ready || release_cookie != 300 || packet_cookie != 301)
            $fatal(1, "Release backpressure lost ownership");
        @(negedge clk); ack_valid = 0; release_ready = 1;
        clocks(2); ack(301, 4, 0);
        $display("PASS release backpressure");

        for (n = 0; n < 4; n = n + 1) begin
            put_packet(5, 1514, 40+n, 400+n);
            if (n == 0) error_word = 5*512 + 7;
            if (n == 1) memory[5*512] = 0; // Stale/unpublished DDR header.
            if (n == 2) malformed = -1;
            if (n == 3) malformed = 1;
            submit(5, 1514, 40+n, 400+n);
            await_packet(400+n, 1); read_word(5, 0, 0); ack(400+n, 5, 1);
            error_word = -1;
        end
        before_requests = requests;
        submit(6, 2045, 44, 404); await_packet(404, 1); ack(404, 6, 1);
        submit(6, 60, 1, 405); await_packet(405, 1); ack(405, 6, 1);
        if (requests != before_requests) $fatal(1, "Invalid descriptor read DDR");
        $display("PASS SLVERR, stale header, early/late RLAST, invalid descriptors");

        allow_ar = 0;
        put_packet(7, 1514, 50, 500); submit(7, 1514, 50, 500);
        while (!arvalid) clocks(1);
        do_flush(); clocks(10);
        if (!arvalid || desc_ready || flush_done || packet_valid)
            $fatal(1, "Flush cancelled stalled AR or published data");
        @(negedge clk); allow_ar = 1;
        await_flush();
        put_packet(7, 61, 51, 501); submit(7, 61, 51, 501);
        verify_packet(7, 61, 51, 501); ack(501, 7, 0);
        $display("PASS flush with stalled AR, drain then slot reuse");

        put_packet(8, 1514, 52, 502); submit(8, 1514, 52, 502);
        while (!pending) clocks(1);
        @(negedge clk); allow_r = 0;
        do_flush(); clocks(2500); // 25 us, beyond the rejected 10 us watchdog.
        if (flush_done || desc_ready || packet_valid || arvalid)
            $fatal(1, "Reused port while old response was owed");
        @(negedge clk); allow_r = 1;
        await_flush();
        put_packet(8, 1514, 53, 503); submit(8, 1514, 53, 503);
        verify_packet(8, 1514, 53, 503); ack(503, 8, 0);
        $display("PASS long delayed tail across logical reset");

        allow_ar = 0;
        put_packet(9, 1514, 54, 504); submit(9, 1514, 54, 504);
        while (!arvalid) clocks(1);
        do_flush(); reset_fabric();
        allow_ar = 1;
        put_packet(9, 61, 55, 505); submit(9, 61, 55, 505);
        verify_packet(9, 61, 55, 505); ack(505, 9, 0);
        put_packet(10, 1514, 56, 506); submit(10, 1514, 56, 506);
        while (!pending) clocks(1);
        reset_fabric();
        put_packet(10, 61, 57, 507); submit(10, 61, 57, 507);
        verify_packet(10, 61, 57, 507); ack(507, 10, 0);
        $display("PASS combined logical/fabric reset and fabric reset mid-burst");
        clocks(3);
        if (packet_valid || release_valid || pending || arvalid) $fatal(1, "Not idle at end");
        if (releases - release_offset != 39)
            $fatal(1, "Missing/duplicate release: got %d expected 39", releases-release_offset);
        $display("ALL PASS: requests=%0d responses=%0d releases=%0d", requests, responses, releases);
        $finish;
    end
endmodule
