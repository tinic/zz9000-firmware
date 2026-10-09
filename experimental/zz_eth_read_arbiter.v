// SPDX-License-Identifier: MIT
// Offline integration model: one physical AXI read owner, two request clients.
// Not connected to the live mntzorro m00 port. See the packet-window README.
`timescale 1ns/1ps
module zz_eth_read_arbiter #(
    parameter ID_WIDTH = 1
) (
    input wire clk,
    input wire aresetn,
    // A demand DDR read is imminent. NOT a bank-window read waiting on prefetch.
    input wire foreground_pending,

    input wire [31:0] fg_araddr,
    input wire [7:0] fg_arlen,
    input wire [1:0] fg_arburst,
    input wire [3:0] fg_arcache,
    input wire [2:0] fg_arprot,
    input wire [ID_WIDTH-1:0] fg_arid,
    input wire fg_arvalid,
    output wire fg_arready,
    output wire [31:0] fg_rdata,
    output wire [1:0] fg_rresp,
    output wire [ID_WIDTH-1:0] fg_rid,
    output wire fg_rlast,
    output wire fg_rvalid,
    input wire fg_rready,

    input wire [31:0] bg_araddr,
    input wire [7:0] bg_arlen,
    input wire [1:0] bg_arburst,
    input wire [3:0] bg_arcache,
    input wire [2:0] bg_arprot,
    input wire [ID_WIDTH-1:0] bg_arid,
    input wire bg_arvalid,
    output wire bg_arready,
    output wire [31:0] bg_rdata,
    output wire [1:0] bg_rresp,
    output wire [ID_WIDTH-1:0] bg_rid,
    output wire bg_rlast,
    output wire bg_rvalid,
    input wire bg_rready,

    output reg [31:0] araddr,
    output reg [7:0] arlen,
    output wire [2:0] arsize,
    output reg [1:0] arburst,
    output reg [3:0] arcache,
    output reg [2:0] arprot,
    output reg [ID_WIDTH-1:0] arid,
    output wire arvalid,
    input wire arready,
    input wire [31:0] rdata,
    input wire [1:0] rresp,
    input wire [ID_WIDTH-1:0] rid,
    input wire rlast,
    input wire rvalid,
    output wire rready
);
    localparam IDLE = 2'd0, ADDRESS = 2'd1, RESPONSE = 2'd2;
    reg [1:0] state;
    reg background;

    assign arsize = 3'd2; // Both existing m00 demand reads and packet reads are 32-bit.
    assign arvalid = aresetn && state == ADDRESS;
    assign fg_arready = arvalid && arready && !background;
    assign bg_arready = arvalid && arready && background;
    assign fg_rdata = rdata;
    assign bg_rdata = rdata;
    assign fg_rresp = rresp;
    assign bg_rresp = rresp;
    // One transaction is outstanding, so ownership selects the response client.
    // Preserve RID for that client's checking; do not route a response by RID.
    assign fg_rid = rid;
    assign bg_rid = rid;
    assign fg_rlast = rlast;
    assign bg_rlast = rlast;
    assign fg_rvalid = aresetn && state == RESPONSE && !background && rvalid;
    assign bg_rvalid = aresetn && state == RESPONSE && background && rvalid;
    assign rready = aresetn && state == RESPONSE &&
                    (background ? bg_rready : fg_rready);

    always @(posedge clk) begin
        if (!aresetn) begin
            state <= IDLE;
            background <= 0;
            araddr <= 0;
            arlen <= 0;
            arburst <= 0;
            arcache <= 0;
            arprot <= 0;
            arid <= 0;
        end else begin
            case (state)
                IDLE: begin
                    if (fg_arvalid) begin
                        background <= 0;
                        araddr <= fg_araddr;
                        arlen <= fg_arlen;
                        arburst <= fg_arburst;
                        arcache <= fg_arcache;
                        arprot <= fg_arprot;
                        arid <= fg_arid;
                        state <= ADDRESS;
                    end else if (bg_arvalid && !foreground_pending) begin
                        background <= 1;
                        araddr <= bg_araddr;
                        arlen <= bg_arlen;
                        arburst <= bg_arburst;
                        arcache <= bg_arcache;
                        arprot <= bg_arprot;
                        arid <= bg_arid;
                        state <= ADDRESS;
                    end
                end
                // A foreground arrival here cannot cancel a selected background
                // address: physical ARVALID must stay stable until acceptance.
                ADDRESS: if (arready) state <= RESPONSE;
                RESPONSE: if (rvalid && rready && rlast) state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
    // Logical reset belongs to clients: keep their requests/responses owned until
    // LAST, even if a client is flushing. Only shared fabric reset cancels this owner.
endmodule
