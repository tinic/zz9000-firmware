// SPDX-License-Identifier: MIT
// Experimental same-clock CSR backend; no live register addresses assigned.
// CSR writes are already-decoded, one-cycle accepted bus transactions. The
// adapter must preserve that transaction's result, not turn it into a retry.
// LAST_RESULT permits normal BUSY rejection without an ARM bus-error exception.
`timescale 1ns/1ps
module zz_eth_packet_mailbox (
    input wire clk, aresetn,
    input wire csr_write,
    input wire [3:0] csr_word,
    input wire [31:0] csr_wdata,
    input wire [3:0] csr_wstrb,
    output reg csr_error,
    input wire [3:0] csr_read_word,
    output reg [31:0] csr_rdata,
    input wire flush_request, // A level is edge-detected; REARM waits for it to fall.
    output wire core_flush,
    input wire core_flush_done,

    output wire desc_valid,
    input wire desc_ready,
    output reg [6:0] desc_slot,
    output reg [11:0] desc_length,
    output reg [15:0] desc_serial,
    output reg [31:0] desc_cookie,
    output reg [1:0] desc_csum,
    input wire release_valid,
    output wire release_ready,
    input wire [6:0] release_slot,
    input wire [31:0] release_cookie,
    input wire release_error
);
    localparam STATUS = 0, SHADOW_COOKIE = 1, SHADOW_META = 2, SHADOW_SLOT = 3,
               COMMIT = 4, RELEASE_COOKIE = 5, RELEASE_META = 6, POP = 7, CONTROL = 8,
               LAST_RESULT = 9;
    localparam HALTED = 0, DRAINING = 1, RUNNING = 2;
    reg [1:0] mode;
    reg drained, external_seen, pending, held;
    reg [31:0] shadow_cookie, shadow_meta, shadow_slot;
    reg [2:0] dirty;
    reg [31:0] held_cookie;
    reg [6:0] held_slot;
    reg held_error;
    reg [31:0] last_result;
    wire flush_command = csr_write && csr_word == CONTROL &&
                         csr_wstrb == 4'hf && csr_wdata == 1;
    wire start_flush = aresetn && mode != DRAINING &&
                       (flush_command || (flush_request && !external_seen));
    assign core_flush = start_flush; // Pulse once, then wait for the core's drain.
    assign desc_valid = aresetn && mode == RUNNING && !start_flush && pending;
    assign release_ready = aresetn && mode == RUNNING && !start_flush && !held;

    // Failed writes complete with error and have no side effect. In particular,
    // COMMIT never stalls the ARM bus while it may need to POP a release.
    always @* begin
        csr_error = 0;
        if (csr_write) begin
            if (!aresetn || csr_wstrb != 4'hf || (start_flush && !flush_command))
                csr_error = 1;
            else case (csr_word)
                SHADOW_COOKIE, SHADOW_META, SHADOW_SLOT:
                    csr_error = mode != RUNNING;
                COMMIT:
                    csr_error = mode != RUNNING || pending || dirty != 3'b111 ||
                        shadow_cookie == 0 || csr_wdata != shadow_cookie ||
                        shadow_meta[15:12] != 0 || shadow_slot[31:9] != 0;
                POP:
                    csr_error = mode != RUNNING || !held || csr_wdata != held_cookie;
                CONTROL:
                    if (csr_wdata == 1) csr_error = 0;
                    else if (csr_wdata == 2)
                        csr_error = mode != HALTED || !drained || flush_request;
                    else csr_error = 1;
                default: csr_error = 1;
            endcase
        end
    end
    always @* begin
        csr_rdata = 0;
        case (csr_read_word)
            STATUS: csr_rdata = {21'b0, dirty, 2'b0, held, pending, drained,
                                mode == HALTED, mode == DRAINING, mode == RUNNING};
            SHADOW_COOKIE: csr_rdata = shadow_cookie;
            SHADOW_META: csr_rdata = shadow_meta;
            SHADOW_SLOT: csr_rdata = shadow_slot;
            RELEASE_COOKIE: if (held && mode == RUNNING && !start_flush) csr_rdata = held_cookie;
            RELEASE_META: if (held && mode == RUNNING && !start_flush)
                csr_rdata = {24'b0, held_error, held_slot};
            LAST_RESULT: csr_rdata = last_result;
            default: csr_rdata = 0;
        endcase
    end

    always @(posedge clk) begin
        if (!aresetn) begin
            mode <= HALTED;
            drained <= 0; // Even initial startup requires explicit FLUSH then REARM.
            external_seen <= 0;
            pending <= 0;
            held <= 0;
            dirty <= 0;
            shadow_cookie <= 0;
            shadow_meta <= 0;
            shadow_slot <= 0;
            desc_slot <= 0;
            desc_length <= 0;
            desc_serial <= 0;
            desc_cookie <= 0;
            desc_csum <= 0;
            held_cookie <= 0;
            held_slot <= 0;
            held_error <= 0;
            last_result <= 0;
        end else begin
            external_seen <= flush_request;
            if (csr_write) last_result <= {23'b0, 1'b1, csr_word, 3'b0, csr_error};
            if (desc_valid && desc_ready) pending <= 0;
            if (release_valid && release_ready) begin
                held <= 1;
                held_cookie <= release_cookie;
                held_slot <= release_slot;
                held_error <= release_error;
            end
            if (csr_write && !csr_error) begin
                case (csr_word)
                    SHADOW_COOKIE: begin shadow_cookie <= csr_wdata; dirty[0] <= 1; end
                    SHADOW_META: begin shadow_meta <= csr_wdata; dirty[1] <= 1; end
                    SHADOW_SLOT: begin shadow_slot <= csr_wdata; dirty[2] <= 1; end
                    COMMIT: begin
                        desc_cookie <= shadow_cookie;
                        desc_length <= shadow_meta[11:0];
                        desc_serial <= shadow_meta[31:16];
                        desc_slot <= shadow_slot[6:0];
                        desc_csum <= shadow_slot[8:7];
                        pending <= 1;
                        dirty <= 0;
                    end
                    POP: held <= 0;
                    CONTROL: if (csr_wdata == 2) begin mode <= RUNNING; drained <= 0; end
                    default: begin end
                endcase
            end
            if (mode == DRAINING && core_flush_done) begin
                // Core and this backend are empty. Upstream MMIO, GEM and host
                // fences are still the adapter/software's separate obligation.
                pending <= 0;
                held <= 0;
                dirty <= 0;
                drained <= 1;
                mode <= HALTED;
            end
            if (start_flush) begin
                mode <= DRAINING;
                drained <= 0;
                dirty <= 0;
                // Keep queued ownership until core_flush_done; no early reuse.
            end
        end
    end
endmodule
