// SPDX-License-Identifier: MIT
// Experimental local-aperture AXI-Lite adapter. See AXILITE.md for reset ordering.
`timescale 1ns/1ps
module zz_eth_packet_axilite #(
    parameter ADDR_WIDTH = 12 // At least 6; address relative to the selected aperture.
) (
    input wire clk, aresetn,
    input wire [ADDR_WIDTH-1:0] s_axi_awaddr,
    input wire [2:0] s_axi_awprot,
    input wire s_axi_awvalid,
    output wire s_axi_awready,
    input wire [31:0] s_axi_wdata,
    input wire [3:0] s_axi_wstrb,
    input wire s_axi_wvalid,
    output wire s_axi_wready,
    output reg [1:0] s_axi_bresp,
    output reg s_axi_bvalid,
    input wire s_axi_bready,
    input wire [ADDR_WIDTH-1:0] s_axi_araddr,
    input wire [2:0] s_axi_arprot,
    input wire s_axi_arvalid,
    output wire s_axi_arready,
    output reg [31:0] s_axi_rdata,
    output reg [1:0] s_axi_rresp,
    output reg s_axi_rvalid,
    input wire s_axi_rready,

    // Same-clock controller signals, deliberately separate from this bus.
    input wire quiesce_request, resume,
    output wire quiesced, local_drained,
    output wire csr_write,
    output wire [3:0] csr_word,
    output wire [31:0] csr_wdata,
    output wire [3:0] csr_wstrb,
    output wire [3:0] csr_read_word,
    input wire [31:0] csr_rdata
);
    reg fenced, aw_held, w_held;
    reg [ADDR_WIDTH-1:0] awaddr;
    reg [31:0] wdata;
    reg [3:0] wstrb;
    wire admitting = !fenced && !quiesce_request;
    // After quiesce, only the missing half of an accepted write may enter.
    assign s_axi_awready = aresetn && !aw_held && !s_axi_bvalid && (admitting || w_held);
    assign s_axi_wready = aresetn && !w_held && !s_axi_bvalid && (admitting || aw_held);
    assign s_axi_arready = aresetn && admitting && !s_axi_rvalid;
    wire write_complete = aresetn && aw_held && w_held && !s_axi_bvalid;
    wire write_address_ok = awaddr < 40 && awaddr[1:0] == 0;
    wire read_address_ok = s_axi_araddr < 40 && s_axi_araddr[1:0] == 0;
    assign csr_write = write_complete && write_address_ok;
    assign csr_word = awaddr[5:2];
    assign csr_wdata = wdata;
    assign csr_wstrb = wstrb;
    assign csr_read_word = s_axi_araddr[5:2];
    assign quiesced = aresetn && (fenced || quiesce_request);
    assign local_drained = aresetn && fenced && !aw_held && !w_held &&
                           !s_axi_bvalid && !s_axi_rvalid;

    always @(posedge clk) begin
        if (!aresetn) begin
            fenced <= 1;
            aw_held <= 0; w_held <= 0;
            awaddr <= 0; wdata <= 0; wstrb <= 0;
            s_axi_bvalid <= 0; s_axi_bresp <= 0;
            s_axi_rvalid <= 0; s_axi_rresp <= 0; s_axi_rdata <= 0;
        end else begin
            if (quiesce_request) fenced <= 1;
            else if (resume && local_drained) fenced <= 0;
            if (s_axi_awvalid && s_axi_awready) begin
                awaddr <= s_axi_awaddr; aw_held <= 1;
            end
            if (s_axi_wvalid && s_axi_wready) begin
                wdata <= s_axi_wdata; wstrb <= s_axi_wstrb; w_held <= 1;
            end
            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 0;
            if (write_complete) begin
                aw_held <= 0; w_held <= 0;
                s_axi_bvalid <= 1;
                // Logical CSR rejection is read through LAST_RESULT, not SLVERR.
                s_axi_bresp <= write_address_ok ? 2'b00 : 2'b10;
            end
            if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 0;
            if (s_axi_arvalid && s_axi_arready) begin
                s_axi_rvalid <= 1;
                s_axi_rdata <= read_address_ok ? csr_rdata : 32'b0;
                s_axi_rresp <= read_address_ok ? 2'b00 : 2'b10;
            end
        end
    end
    // AWPROT/ARPROT are intentionally ignored: privilege/security decoding is
    // the enclosing interconnect's responsibility, not a local CSR property.
endmodule
