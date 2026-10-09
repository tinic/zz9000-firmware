// SPDX-License-Identifier: MIT
// Offline same-clock integration wrapper; no live register allocation or bitstream.
// Logical flush belongs to the packet client; the physical owner only sees fabric reset.
`timescale 1ns/1ps
module zz_eth_packet_engine #(
    parameter ADDR_WIDTH = 12,
    parameter ID_WIDTH = 1,
    parameter [31:0] RX_BASE = 32'h3fe00000,
    parameter [3:0] PACKET_ARCACHE = 4'hf,
    parameter [2:0] PACKET_ARPROT = 3'h0,
    parameter [ID_WIDTH-1:0] PACKET_ARID = 0
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
    output wire [1:0] s_axi_bresp,
    output wire s_axi_bvalid,
    input wire s_axi_bready,
    input wire [ADDR_WIDTH-1:0] s_axi_araddr,
    input wire [2:0] s_axi_arprot,
    input wire s_axi_arvalid,
    output wire s_axi_arready,
    output wire [31:0] s_axi_rdata,
    output wire [1:0] s_axi_rresp,
    output wire s_axi_rvalid,
    input wire s_axi_rready,

    // Same-clock controller signals, deliberately separate from this bus.
    input wire quiesce_request, resume,
    output wire quiesced, local_drained,
    input wire flush_request,
    // Packet core pulse only: not a shared-port, upstream, GEM or host fence.
    output wire core_flush_done,

    output wire packet_valid,
    output wire packet_error,
    output wire [11:0] packet_length,
    output wire [15:0] packet_serial,
    output wire [31:0] packet_cookie,
    output wire [1:0] packet_csum,
    input wire host_read,
    input wire [8:0] host_word,
    output wire host_read_valid,
    output wire [31:0] host_data, // Raw AXI byte order; adapter performs Zorro swap.
    input wire ack_valid,
    input wire [31:0] ack_cookie,
    output wire ack_ready,

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

    output wire [31:0] araddr,
    output wire [7:0] arlen,
    output wire [2:0] arsize,
    output wire [1:0] arburst,
    output wire [3:0] arcache,
    output wire [2:0] arprot,
    output wire [ID_WIDTH-1:0] arid,
    output wire arvalid,
    input wire arready,
    input wire [31:0] rdata,
    input wire [1:0] rresp,
    input wire [ID_WIDTH-1:0] rid,
    input wire rlast,
    input wire rvalid,
    output wire rready
);
    wire csr_write, csr_error, core_flush;
    wire [3:0] csr_word, csr_wstrb, csr_read_word;
    wire [31:0] csr_wdata, csr_rdata;
    wire desc_valid, desc_ready, release_valid, release_ready, release_error;
    wire [6:0] desc_slot, release_slot;
    wire [11:0] desc_length;
    wire [15:0] desc_serial;
    wire [31:0] desc_cookie, release_cookie;
    wire [1:0] desc_csum;
    wire [31:0] bg_araddr, bg_rdata;
    wire [7:0] bg_arlen;
    wire [2:0] bg_arsize;
    wire [1:0] bg_arburst, bg_rresp;
    wire [ID_WIDTH-1:0] bg_rid;
    wire bg_arvalid, bg_arready, bg_rlast, bg_rvalid, bg_rready;

    zz_eth_packet_axilite #(.ADDR_WIDTH(ADDR_WIDTH)) adapter (
        .clk(clk), .aresetn(aresetn), .s_axi_awaddr(s_axi_awaddr), .s_axi_awprot(s_axi_awprot),
        .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready), .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready), .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready), .s_axi_araddr(s_axi_araddr), .s_axi_arprot(s_axi_arprot), .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready), .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready), .quiesce_request(quiesce_request), .resume(resume), .quiesced(quiesced),
        .local_drained(local_drained), .csr_write(csr_write), .csr_word(csr_word), .csr_wdata(csr_wdata),
        .csr_wstrb(csr_wstrb), .csr_read_word(csr_read_word), .csr_rdata(csr_rdata)
    );
    zz_eth_packet_mailbox mailbox (
        .clk(clk), .aresetn(aresetn), .csr_write(csr_write), .csr_word(csr_word),
        .csr_wdata(csr_wdata), .csr_wstrb(csr_wstrb), .csr_error(csr_error), .csr_read_word(csr_read_word),
        .csr_rdata(csr_rdata), .flush_request(flush_request), .core_flush(core_flush), .core_flush_done(core_flush_done),
        .desc_valid(desc_valid), .desc_ready(desc_ready), .desc_slot(desc_slot), .desc_length(desc_length),
        .desc_serial(desc_serial), .desc_cookie(desc_cookie), .desc_csum(desc_csum), .release_valid(release_valid),
        .release_ready(release_ready), .release_slot(release_slot), .release_cookie(release_cookie), .release_error(release_error)
    );
    zz_eth_packet_window #(.RX_BASE(RX_BASE)) core (
        .clk(clk), .aresetn(aresetn), .flush(core_flush), .flush_done(core_flush_done),
        .desc_valid(desc_valid), .desc_ready(desc_ready), .desc_slot(desc_slot), .desc_length(desc_length),
        .desc_serial(desc_serial), .desc_cookie(desc_cookie), .desc_csum(desc_csum), .packet_valid(packet_valid),
        .packet_error(packet_error), .packet_length(packet_length), .packet_serial(packet_serial), .packet_cookie(packet_cookie),
        .packet_csum(packet_csum), .host_read(host_read), .host_word(host_word), .host_read_valid(host_read_valid),
        .host_data(host_data), .ack_valid(ack_valid), .ack_cookie(ack_cookie), .ack_ready(ack_ready),
        .release_valid(release_valid), .release_ready(release_ready), .release_slot(release_slot), .release_cookie(release_cookie),
        .release_error(release_error), .araddr(bg_araddr), .arlen(bg_arlen), .arsize(bg_arsize),
        .arburst(bg_arburst), .arvalid(bg_arvalid), .arready(bg_arready), .rdata(bg_rdata),
        .rresp(bg_rresp), .rlast(bg_rlast), .rvalid(bg_rvalid), .rready(bg_rready)
    );
    zz_eth_read_arbiter #(.ID_WIDTH(ID_WIDTH)) arbiter (
        .clk(clk), .aresetn(aresetn), .foreground_pending(foreground_pending), .fg_araddr(fg_araddr),
        .fg_arlen(fg_arlen), .fg_arburst(fg_arburst), .fg_arcache(fg_arcache), .fg_arprot(fg_arprot),
        .fg_arid(fg_arid), .fg_arvalid(fg_arvalid), .fg_arready(fg_arready), .fg_rdata(fg_rdata),
        .fg_rresp(fg_rresp), .fg_rid(fg_rid), .fg_rlast(fg_rlast), .fg_rvalid(fg_rvalid),
        .fg_rready(fg_rready), .bg_araddr(bg_araddr), .bg_arlen(bg_arlen), .bg_arburst(bg_arburst),
        .bg_arcache(PACKET_ARCACHE), .bg_arprot(PACKET_ARPROT), .bg_arid(PACKET_ARID), .bg_arvalid(bg_arvalid),
        .bg_arready(bg_arready), .bg_rdata(bg_rdata), .bg_rresp(bg_rresp), .bg_rid(bg_rid),
        .bg_rlast(bg_rlast), .bg_rvalid(bg_rvalid), .bg_rready(bg_rready), .araddr(araddr),
        .arlen(arlen), .arsize(arsize), .arburst(arburst), .arcache(arcache),
        .arprot(arprot), .arid(arid), .arvalid(arvalid), .arready(arready),
        .rdata(rdata), .rresp(rresp), .rid(rid), .rlast(rlast),
        .rvalid(rvalid), .rready(rready)
    );
endmodule
