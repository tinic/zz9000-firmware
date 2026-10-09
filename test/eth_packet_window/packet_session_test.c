/* SPDX-License-Identifier: MIT
 * Fixture for actual fence/rearm/clear/reset-caller bodies from firmware.
 * Covers software lifetime gates, not GEM/GIC, cache ordering or fabric reset.
 */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "../../experimental/zz_eth_packet_transport.h"
typedef uint32_t u32;
typedef uint16_t u16;
#define ETH_PACKET_FENCE_OFFSET 0x24u
#define ETH_PACKET_HOST_DRAINED 1u
#define ETH_PACKET_LINK_DRAINED 2u
#define ETH_PACKET_FENCE_STOP 1u
#define ETH_PACKET_FENCE_RESUME 2u
#define MNTZ_BASE_ADDR 0u
#define MNTZORRO_REG4 16u
#define XEMACPS_NWCTRL_OFFSET 0u
#define XEMACPS_NWCTRL_RXEN_MASK 4u
#define XEMACPS_NWCTRL_TXEN_MASK 8u
#define ETH_TASK_READY 2
#define ETH_CONFIG_HASH_RESET 0x8000u
#define RXBD_CNT 64
#define FRAME_MAX_BACKLOG 128
#define ETH_INVALID_BACKLOG_SLOT 0xffffu
#define dsb() ((void)0)
static struct { struct { unsigned BaseAddress; } Config; } EmacPsInstance;
static struct zz_rx_lease packet_leases;
static int packet_mode, packet_active, packet_can_clear, packet_fault;
static int packet_session_started, ethernet_task_state, rx_backpressure;
static u16 frames_backlog, frames_backlog_read, frames_backlog_write;
static u16 frames_backlog_reserved, frames_backlog_reserve, frame_serial;
static unsigned frames_received, FramesRx, FramesTx, frames_dropped;
static unsigned frames_backlog_full, rx_pause_frames, rx_slot_mismatch;
static u16 rx_bd_backlog_slot[RXBD_CNT];
static unsigned slot_clears[FRAME_MAX_BACKLOG];
static unsigned host_bits, core_bits, gem_ctrl, stop_writes, resume_writes;
static unsigned flush_writes, rearm_writes, clear_writes, tx_flushes;
static unsigned irq_depth, irq_pauses, restart_calls, hash_resets;
static u32 command_result;
static int eth_tx_ord;
static void mntzorro_write(unsigned base, unsigned offset, u32 value)
{
    (void)base;
    if (offset == MNTZORRO_REG4) { assert(value == 0); clear_writes++; return; }
    assert(offset == ETH_PACKET_FENCE_OFFSET);
    if (value == ETH_PACKET_FENCE_STOP) {
        assert(packet_leases.flushing && !packet_active && !packet_can_clear);
        stop_writes++;
    } else {
        assert(value == ETH_PACKET_FENCE_RESUME && rearm_writes);
        assert(command_result == 0x180u && packet_can_clear && !packet_fault);
        resume_writes++;
    }
}
static u32 mntzorro_read(unsigned base, unsigned offset)
{ (void)base; assert(offset == ETH_PACKET_FENCE_OFFSET); return host_bits; }
static u32 XEmacPs_ReadReg(unsigned base, unsigned offset)
{ (void)base; (void)offset; return gem_ctrl; }
static u32 ethernet_packet_read(void *ctx, unsigned word)
{
    (void)ctx;
    if (word == ZZ_PKT_RESULT) return command_result;
    assert(word == ZZ_PKT_STATUS && flush_writes);
    return core_bits;
}
static void write_word(void *ctx, unsigned word, u32 value)
{
    (void)ctx; assert(word == ZZ_PKT_CONTROL);
    if (value == 1u) {
        assert(host_bits == 3u && stop_writes && packet_leases.flushing);
        flush_writes++;
    } else {
        assert(value == 2u && packet_can_clear && !packet_fault);
        rearm_writes++;
    }
}
static const struct zz_pkt_io packet_io = {ethernet_packet_read, write_word, 0};
static void eth_tx_order_flush(int *order)
{ assert(order == &eth_tx_ord); tx_flushes++; }
static void ethernet_clear_backlog_slot(int slot)
{ assert(slot >= 0 && slot < FRAME_MAX_BACKLOG); slot_clears[slot]++; }
static void ethernet_log_status(const char *reason) { (void)reason; }
static void ethernet_set_multicast_hash(u16 command)
{ assert(command == ETH_CONFIG_HASH_RESET); hash_resets++; }
static int ethernet_pause_rx_irq(void)
{ assert(!irq_depth); irq_depth++; irq_pauses++; return 1; }
static void ethernet_resume_rx_irq(int paused)
{ assert(paused == 1 && irq_depth == 1); irq_depth--; }
static int ethernet_restart_dma(const char *reason)
{ assert(strcmp(reason, "amiga-reset") == 0); restart_calls++; return 0; }
/* EXACT_SESSION_BODIES */
static void setup(void)
{
    zz_rx_lease_init(&packet_leases);
    packet_leases.next_cookie = 400;
    packet_mode = 1;
    packet_active = packet_can_clear = packet_fault = packet_session_started = 0;
    ethernet_task_state = 0;
    frames_backlog = frames_backlog_read = frames_backlog_write = 7;
    frames_backlog_reserved = frames_backlog_reserve = frame_serial = 7;
    frames_received = FramesRx = FramesTx = frames_dropped = 7;
    frames_backlog_full = rx_pause_frames = rx_slot_mismatch = 7;
    rx_backpressure = 1;
    for (unsigned i = 0; i < RXBD_CNT; i++) rx_bd_backlog_slot[i] = 7;
    memset(slot_clears, 0, sizeof(slot_clears));
    host_bits = 3; core_bits = ZZ_PKT_HALTED | ZZ_PKT_DRAIN_COMPLETE;
    command_result = 0x180; gem_ctrl = 0;
    stop_writes = resume_writes = flush_writes = rearm_writes = 0;
    clear_writes = tx_flushes = irq_depth = irq_pauses = restart_calls = hash_resets = 0;
}
static void cleared(void)
{
    assert(clear_writes == 1 && tx_flushes == 1);
    assert(!frames_backlog && !frames_backlog_reserved && !frames_backlog_read);
    assert(!frames_backlog_write && !frames_backlog_reserve && !frame_serial);
    assert(!frames_received && !FramesRx && !FramesTx && !frames_dropped);
    assert(!frames_backlog_full && !rx_backpressure && !rx_pause_frames && !rx_slot_mismatch);
    for (unsigned i = 0; i < RXBD_CNT; i++)
        assert(rx_bd_backlog_slot[i] == ETH_INVALID_BACKLOG_SLOT);
    for (unsigned i = 0; i < FRAME_MAX_BACKLOG; i++) assert(slot_clears[i] == 1);
}
static void uncleared(void)
{
    assert(!clear_writes && !tx_flushes && frames_backlog == 7);
    assert(frames_backlog_reserved == 7 && frame_serial == 7);
    for (unsigned i = 0; i < RXBD_CNT; i++) assert(rx_bd_backlog_slot[i] == 7);
    for (unsigned i = 0; i < FRAME_MAX_BACKLOG; i++) assert(slot_clears[i] == 0);
}
static void start_session(void)
{
    packet_can_clear = 1;
    assert(ethernet_packet_rearm());
    assert(packet_session_started && packet_active && !packet_can_clear);
    assert(rearm_writes == 1 && resume_writes == 1);
}
int main(void)
{
    setup(); ethernet_reset_for_amiga();
    assert(!packet_fault && !packet_session_started && !packet_active);
    assert(irq_pauses == 1 && !irq_depth && !restart_calls && hash_resets == 1);
    assert(!stop_writes && !rearm_writes); cleared();
    puts("PASS actual not-READY cold reset: clear before first session");

    for (unsigned failure = 0; failure < 4; failure++) {
        setup(); packet_can_clear = failure != 0;
        if (failure == 1) packet_fault = 1;
        if (failure == 2) command_result = 0x181; /* explicit rejection */
        if (failure == 3) command_result = 0;     /* ambiguous result */
        assert(!ethernet_packet_rearm());
        assert(!packet_session_started && !packet_active && !resume_writes);
        assert(rearm_writes == (failure >= 2));
        ethernet_reset_for_amiga(); cleared();
    }
    puts("PASS actual failed first rearm: no submissions enabled");

    setup(); start_session(); ethernet_reset_for_amiga();
    assert(packet_fault && packet_session_started && !restart_calls); uncleared();
    setup(); start_session(); packet_active = 0;
    assert(packet_leases.count == 0); ethernet_reset_for_amiga();
    assert(packet_fault && packet_session_started && !irq_depth); uncleared();
    puts("PASS actual later not-READY reset: active and empty/inactive sessions stay guarded");

    for (unsigned failure = 0; failure < 4; failure++) {
        setup(); start_session();
        packet_leases.count = 1; packet_leases.state[0] = ZZ_RX_OWNED;
        if (failure == 0) host_bits = 0;
        if (failure == 1) command_result = 0x181;
        if (failure == 2) core_bits = 0;
        if (failure == 3) gem_ctrl = XEMACPS_NWCTRL_RXEN_MASK;
        assert(!ethernet_packet_fence());
        assert(packet_fault && packet_session_started && !packet_active && !packet_can_clear);
        assert(packet_leases.count == 1 && zz_rx_lease_pinned(&packet_leases, 0));
        ethernet_reset_for_amiga(); uncleared();
        assert(packet_leases.count == 1 && packet_leases.next_cookie == 400);
    }
    puts("PASS actual failed fences: session marker and lease pinning survive reset caller");

    setup(); start_session();
    packet_leases.count = 1; packet_leases.state[0] = ZZ_RX_OWNED;
    assert(ethernet_packet_fence());
    assert(packet_session_started && packet_can_clear && !packet_fault && !packet_active);
    assert(!packet_leases.count && packet_leases.next_cookie == 400);
    ethernet_reset_for_amiga(); cleared(); assert(packet_session_started);
    assert(ethernet_packet_rearm()); assert(packet_session_started && packet_active);
    puts("PASS actual completed fence: reclaim/clear/rearm preserve session history");

    setup(); packet_mode = 0; packet_session_started = 1;
    ethernet_reset_for_amiga(); cleared();
    assert(!packet_fault && !stop_writes && !rearm_writes);
    assert(ethernet_packet_fence() && ethernet_packet_rearm());
    setup(); ethernet_task_state = ETH_TASK_READY; ethernet_reset_for_amiga();
    assert(restart_calls == 1 && !irq_pauses && hash_resets == 1); uncleared();
    puts("PASS actual caller: legacy clear preserved; READY delegates to DMA restart");
    return 0;
}
