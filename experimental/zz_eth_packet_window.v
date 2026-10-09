// SPDX-License-Identifier: MIT
// Offline prototype. Not connected to mntzorro or included in a bitstream.
// See test/eth_packet_window/README.md for the producer/reset contract.
`timescale 1ns/1ps
module zz_eth_packet_window #(
    parameter [31:0] RX_BASE = 32'h3fe00000
) (
    input wire clk,
    input wire aresetn,       // Resets this master AND its AXI interconnect.
    input wire flush,         // Logical cancellation; outstanding AXI is drained.
    output reg flush_done,

    input wire desc_valid,
    output wire desc_ready,
    input wire [6:0] desc_slot,
    input wire [11:0] desc_length, // Ethernet bytes; excludes 4-byte window header.
    input wire [15:0] desc_serial,
    input wire [31:0] desc_cookie, // Producer epoch/ticket, also used for host ACK.
    input wire [1:0] desc_csum,

    output wire packet_valid,
    // Head packet accepted but not yet READY: a host read may wait for it.
    output wire head_busy,
    output wire packet_error,
    output wire [11:0] packet_length,
    output wire [15:0] packet_serial,
    output wire [31:0] packet_cookie,
    output wire [1:0] packet_csum,
    input wire host_read,
    input wire [8:0] host_word,
    output reg host_read_valid,
    output reg [31:0] host_data, // Raw AXI byte order; adapter performs Zorro swap.
    input wire ack_valid,
    input wire [31:0] ack_cookie,
    output wire ack_ready,

    output reg release_valid,
    input wire release_ready,
    output reg [6:0] release_slot,
    output reg [31:0] release_cookie,
    output reg release_error,

    output reg [31:0] araddr,
    output reg [7:0] arlen,
    output wire [2:0] arsize,
    output wire [1:0] arburst,
    output reg arvalid,
    input wire arready,
    input wire [31:0] rdata,
    input wire [1:0] rresp,
    input wire rlast,
    input wire rvalid,
    output wire rready
);
    localparam FREE = 2'd0, QUEUED = 2'd1, FILLING = 2'd2, READY = 2'd3;
    // Separate synchronous-read arrays allow a block-RAM implementation.
    // These attributes are hints; Vivado inference/resource/timing is unverified.
    (* ram_style = "block" *) reg [31:0] ram0 [0:511];
    (* ram_style = "block" *) reg [31:0] ram1 [0:511];
    reg [31:0] ram0_q, ram1_q;
    reg read_bank;
    reg [1:0] state [0:1];
    reg [6:0] slot [0:1];
    reg [11:0] length [0:1];
    reg [15:0] serial [0:1];
    reg [31:0] cookie [0:1];
    reg [1:0] csum [0:1];
    reg [9:0] words [0:1];
    reg bad [0:1];
    reg head, tail;
    reg flushing;
    reg filling, fill_bank;
    reg [9:0] fill_word;
    reg fill_bad;
    reg outstanding;
    reg [4:0] beats_left;
    wire [9:0] words_left = words[fill_bank] - fill_word;
    wire [4:0] next_beats = words_left > 10'd16 ? 5'd16 : words_left[4:0];
    wire [31:0] expected_header = {serial[fill_bank][7:0], serial[fill_bank][15:8],
                                  length[fill_bank][7:0], 4'b0, length[fill_bank][11:8]};
    wire response_bad = rresp != 2'b00 || beats_left == 0 ||
                        (rlast && beats_left != 1) ||
                        (!rlast && beats_left == 1) ||
                        (fill_word == 0 && rdata != expected_header);

    assign arsize = 3'd2;
    assign arburst = 2'b01;
    assign rready = outstanding && aresetn;
    assign desc_ready = aresetn && !flush && !flushing && state[tail] == FREE;
    assign packet_valid = aresetn && !flush && !flushing && state[head] == READY;
    assign head_busy = aresetn && !flush && !flushing &&
                       (state[head] == QUEUED || state[head] == FILLING);
    assign packet_error = bad[head];
    assign packet_length = length[head];
    assign packet_serial = serial[head];
    assign packet_cookie = cookie[head];
    assign packet_csum = csum[head];
    assign ack_ready = packet_valid && ack_cookie == cookie[head] &&
                       (!release_valid || release_ready);
    wire read_ok = host_read && packet_valid && !packet_error &&
                   {1'b0, host_word} < words[head] && !(ack_valid && ack_ready);

    // Memory ports have no reset. Unpublished RAM contents are never returned.
    always @(posedge clk) begin
        if (rvalid && rready && filling && !flushing && !flush &&
            !fill_bad && !response_bad && fill_word < words[fill_bank]) begin
            if (fill_bank) ram1[fill_word[8:0]] <= rdata;
            else           ram0[fill_word[8:0]] <= rdata;
        end
        if (read_ok) begin
            if (head) ram1_q <= ram1[host_word];
            else      ram0_q <= ram0[host_word];
        end
    end
    always @* host_data = read_bank ? ram1_q : ram0_q;

    integer b;
    always @(posedge clk) begin
        if (!aresetn) begin
            head <= 0;
            tail <= 0;
            flushing <= 0;
            flush_done <= 0;
            filling <= 0;
            fill_bank <= 0;
            fill_word <= 0;
            fill_bad <= 0;
            outstanding <= 0;
            beats_left <= 0;
            arvalid <= 0;
            araddr <= 0;
            arlen <= 0;
            host_read_valid <= 0;
            read_bank <= 0;
            release_valid <= 0;
            release_slot <= 0;
            release_cookie <= 0;
            release_error <= 0;
            for (b = 0; b < 2; b = b + 1) begin
                state[b] <= FREE;
                slot[b] <= 0;
                length[b] <= 0;
                serial[b] <= 0;
                cookie[b] <= 0;
                csum[b] <= 0;
                words[b] <= 0;
                bad[b] <= 0;
            end
        end else begin
            flush_done <= 0;
            host_read_valid <= read_ok;
            if (read_ok) read_bank <= head;
            if (release_valid && release_ready) release_valid <= 0;

            // AR ownership survives a logical flush, including a stalled VALID.
            if (arvalid && arready) begin
                arvalid <= 0;
                outstanding <= 1;
                beats_left <= {1'b0, arlen[3:0]} + 5'd1;
            end
            if (rvalid && rready) begin
                if (beats_left != 0) beats_left <= beats_left - 1'b1;
                if (rlast) outstanding <= 0;
                if (filling && !flushing && !flush) begin
                    if (response_bad) fill_bad <= 1;
                    // Saturate: malformed late RLAST must not wrap the write index.
                    if (fill_word < words[fill_bank]) fill_word <= fill_word + 1'b1;
                    if (rlast && (fill_bad || response_bad ||
                                  fill_word + 10'd1 >= words[fill_bank])) begin
                        state[fill_bank] <= READY;
                        bad[fill_bank] <= fill_bad || response_bad;
                        filling <= 0;
                    end
                end
            end

            if (!flush && !flushing) begin
                if (desc_valid && desc_ready) begin
                    slot[tail] <= desc_slot;
                    length[tail] <= desc_length;
                    serial[tail] <= desc_serial;
                    cookie[tail] <= desc_cookie;
                    csum[tail] <= desc_csum;
                    words[tail] <= ({1'b0, desc_length} + 13'd7) >> 2;
                    if (desc_length < 14 || desc_length > 2044 || desc_serial < 2) begin
                        state[tail] <= READY;
                        bad[tail] <= 1;
                    end else begin
                        state[tail] <= QUEUED;
                        bad[tail] <= 0;
                    end
                    tail <= !tail;
                end
                if (ack_valid && ack_ready) begin
                    release_valid <= 1;
                    release_slot <= slot[head];
                    release_cookie <= cookie[head];
                    release_error <= bad[head];
                    state[head] <= FREE;
                    head <= !head;
                end
                if (!filling && !arvalid && !outstanding) begin
                    if (state[head] == QUEUED || state[!head] == QUEUED) begin
                        fill_bank <= state[head] == QUEUED ? head : !head;
                        state[state[head] == QUEUED ? head : !head] <= FILLING;
                        filling <= 1;
                        fill_word <= 0;
                        fill_bad <= 0;
                    end
                end else if (filling && !arvalid && !outstanding) begin
                    // Slots start on 2 KB boundaries and contain <= 2 KB, so
                    // these <= 16-beat bursts cannot cross an AXI 4 KB boundary.
                    araddr <= RX_BASE + {14'b0, slot[fill_bank], 11'b0} +
                              {20'b0, fill_word, 2'b0};
                    arlen <= {3'b0, next_beats} - 8'd1;
                    arvalid <= 1;
                end
            end

            if (flushing && !arvalid && !outstanding) begin
                flushing <= 0;
                flush_done <= 1;
            end
            // Highest priority logical reset: no new publication or ACK.
            // Producer may reclaim all old descriptors only after flush_done.
            if (flush) begin
                flushing <= 1;
                filling <= 0;
                head <= 0;
                tail <= 0;
                state[0] <= FREE;
                state[1] <= FREE;
                release_valid <= 0;
                host_read_valid <= 0;
                flush_done <= 0;
            end
        end
    end
`ifndef SYNTHESIS
    initial begin
        if (RX_BASE[10:0] != 0) $fatal(1, "RX_BASE must be 2 KB aligned");
    end
`endif
endmodule
