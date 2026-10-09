/* SPDX-License-Identifier: MIT
 * Prefix for the exact ethernet_packet_fence body extracted by run_live.py.
 * This models ordered MMIO results; it does not model GEM or the ARM GIC.
 */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include "../../experimental/zz_eth_packet_transport.h"
typedef uint32_t u32;
typedef uint16_t u16;
#define ETH_PACKET_FENCE_OFFSET 0x24u
#define ETH_PACKET_HOST_DRAINED 1u
#define ETH_PACKET_LINK_DRAINED 2u
#define ETH_PACKET_FENCE_STOP 1u
#define ETH_PACKET_READY 4u
#define MNTZ_BASE_ADDR 0u
#define XEMACPS_NWCTRL_OFFSET 0u
#define XEMACPS_NWCTRL_RXEN_MASK 4u
#define XEMACPS_NWCTRL_TXEN_MASK 8u
#define dsb() ((void)0)
static struct { struct { unsigned BaseAddress; } Config; } EmacPsInstance;
static struct zz_rx_lease packet_leases;
static int packet_mode, packet_active, packet_can_clear, packet_fault;
static unsigned host_ready, core_ready, gem_ctrl, stop_writes, flush_writes, reads;
static u32 last_result, ready_bits;
static u16 frames_backlog, frames_backlog_reserved;
static int rx_backpressure;
static void mntzorro_write(unsigned base, unsigned offset, u32 value)
{
    (void)base;
    assert(offset == ETH_PACKET_FENCE_OFFSET && value == ETH_PACKET_FENCE_STOP);
    assert(packet_leases.flushing && !packet_active && !packet_can_clear);
    stop_writes++;
}
static u32 mntzorro_read(unsigned base, unsigned offset)
{
    (void)base; assert(offset == ETH_PACKET_FENCE_OFFSET); reads++;
    return (host_ready ? 3u : 0u) | ready_bits;
}
static u32 XEmacPs_ReadReg(unsigned base, unsigned offset)
{ (void)base; (void)offset; return gem_ctrl; }
static u32 ethernet_packet_read(void *context, unsigned word)
{
    (void)context;
    if (word == ZZ_PKT_RESULT) return last_result;
    assert(word == ZZ_PKT_STATUS && flush_writes);
    return core_ready ? ZZ_PKT_HALTED | ZZ_PKT_DRAIN_COMPLETE : 2u;
}
static void write_word(void *ctx, unsigned word, u32 value)
{
    (void)ctx;
    assert(word == ZZ_PKT_CONTROL && value == 1u);
    assert(host_ready && stop_writes == 1 && packet_leases.flushing);
    assert(packet_leases.count == 1 && packet_leases.state[0] == ZZ_RX_OWNED);
    flush_writes++; last_result = 0x180;
}
static const struct zz_pkt_io packet_io = {ethernet_packet_read, write_word, 0};
/* EXACT_FENCE_BODY */
/* EXACT_STATUS_BODIES */
static void setup(void)
{
    zz_rx_lease_init(&packet_leases);
    packet_leases.count = 1; packet_leases.state[0] = ZZ_RX_OWNED;
    packet_leases.next_cookie = 400;
    packet_mode = packet_active = 1; packet_can_clear = packet_fault = 0;
    stop_writes = flush_writes = reads = 0; host_ready = core_ready = 1;
    gem_ctrl = last_result = 0;
}
int main(void)
{
    setup(); assert(ethernet_packet_fence());
    assert(stop_writes == 1 && flush_writes == 1 && packet_can_clear);
    assert(packet_leases.count == 0 && packet_leases.next_cookie == 400);
    puts("PASS actual fence: host drain before core flush and reclaim");
    setup(); host_ready = 0; assert(!ethernet_packet_fence());
    assert(flush_writes == 0 && reads == 10000 && packet_fault);
    assert(packet_leases.count == 1 && zz_rx_lease_pinned(&packet_leases, 0));
    puts("PASS actual fence: host timeout never flushes/reclaims");
    setup(); core_ready = 0; assert(!ethernet_packet_fence());
    assert(flush_writes == 1 && packet_fault && !packet_can_clear);
    assert(packet_leases.count == 1 && packet_leases.flushing);
    puts("PASS actual fence: missing core drain preserves all leases");
    setup(); gem_ctrl = XEMACPS_NWCTRL_RXEN_MASK; assert(!ethernet_packet_fence());
    assert(packet_leases.count == 1 && !packet_can_clear && packet_fault);
    puts("PASS actual fence: GEM enable readback prevents reuse");
    setup(); ready_bits = 0; frames_backlog = 7; frames_backlog_reserved = 64;
    rx_backpressure = 1;
    assert(ethernet_get_rx_status() == 0xc000u); /* DDR waiting, no bank ready */
    ready_bits = ETH_PACKET_READY;
    assert(ethernet_get_rx_status() == 0xc001u);
    ready_bits = 0;
    assert(ethernet_get_rx_status() == 0xc000u); /* both banks drained */
    ready_bits = ETH_PACKET_READY; packet_active = 0;
    assert(ethernet_get_rx_status() == 0xc000u);
    packet_active = 1; packet_fault = 1;
    assert(ethernet_get_rx_status() == 0xc000u);
    puts("PASS actual status: empty/ready/drained/stopped/faulted bank readiness");
    packet_mode = 0; reads = 0;
    assert(ethernet_get_rx_status() == 0xc007u && reads == 0);
    frames_backlog = 400; frames_backlog_reserved = 200; rx_backpressure = 0;
    assert(ethernet_get_rx_status() == 0x7fffu && reads == 0);
    puts("PASS actual status: legacy backlog/clamps and pressure diagnostics preserved");
    return 0;
}
