/* SPDX-License-Identifier: MIT
 * Actual service/status bodies, real lease/transport helpers, stub hardware.
 * Three queued descriptors model two banks plus one pending mailbox entry;
 * host release and software polling are scheduled explicitly, not RTL timed.
 */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "../../experimental/zz_eth_packet_transport.h"
typedef uint16_t u16;
typedef uint32_t u32;
#define FRAME_MAX_BACKLOG 128u
#define ETH_BACKLOG_LOW_WATERMARK 96u
#define ETH_PACKET_FENCE_OFFSET 0x24u
#define ETH_PACKET_READY 4u
#define MNTZ_BASE_ADDR 0u
static struct zz_rx_lease packet_leases;
static int packet_mode, packet_active, packet_fault, ethernet_hw_ready;
static int rx_backpressure;
static u16 frames_backlog, frames_backlog_read, frames_backlog_reserved;
static u16 packet_length[128], packet_serial[128];
static uint8_t rx_backlog_csum[128];
static unsigned frames_dropped, allocations, clears[128], publishes[128];
static unsigned publish_step[128], running, ready, result, held, pop_failure;
static unsigned writes, commits, pops, count, released_slot, released_error;
static u32 released_cookie, shadow[4];
static struct zz_rx_descriptor queue[3], accepted[128];
static u16 ethernet_next_backlog_slot(u16 slot) { return (slot + 1u) % 128u; }
static u16 ethernet_backlog_pending(void) { return frames_backlog + frames_backlog_reserved; }
static void ethernet_alloc_rx_frames(void)
{ assert(!packet_fault && !rx_backpressure); allocations++; }
static void ethernet_clear_backlog_slot(unsigned slot)
{
    assert(slot < 128 && !zz_rx_lease_pinned(&packet_leases, slot));
    assert(!held || slot != released_slot); /* POP must finish before reuse. */
    clears[slot]++;
}
static u32 mntzorro_read(unsigned base, unsigned offset)
{ (void)base; assert(offset == ETH_PACKET_FENCE_OFFSET); return ready ? ETH_PACKET_READY : 0; }
static u32 ethernet_packet_read(void *context, unsigned word)
{
    (void)context;
    switch (word) {
    case ZZ_PKT_STATUS: return (running ? ZZ_PKT_RUNNING : 0) |
                              (count == 3 ? ZZ_PKT_PENDING : 0) |
                              (held ? ZZ_PKT_RELEASE_HELD : 0);
    case ZZ_PKT_RESULT: return result;
    case ZZ_PKT_RELEASE_COOKIE: assert(held); return released_cookie;
    case ZZ_PKT_RELEASE_META: assert(held); return released_slot | (released_error << 7);
    default: assert(0); return 0;
    }
}
static void write_word(void *context, unsigned word, u32 value)
{
    (void)context; writes++; result = 0x100u | (word << 4);
    if (word >= ZZ_PKT_COOKIE && word <= ZZ_PKT_SLOT) shadow[word] = value;
    else if (word == ZZ_PKT_COMMIT) {
        struct zz_rx_descriptor d;
        assert(count < 3 && commits < 128 && value == shadow[1]);
        d.cookie = value; d.slot = shadow[3] & 127u; d.csum = shadow[3] >> 7;
        d.length = shadow[2] & 65535u; d.serial = shadow[2] >> 16;
        assert(publishes[d.slot] == 1 && publish_step[d.slot] == 3);
        assert(d.length == packet_length[d.slot] && d.serial == packet_serial[d.slot]);
        assert(d.csum == rx_backlog_csum[d.slot]);
        accepted[commits++] = d; queue[count++] = d;
    } else {
        assert(word == ZZ_PKT_POP && held && value == released_cookie);
        if (pop_failure) { result = pop_failure == 1 ? result | 1u : 0; return; }
        held = 0; pops++;
    }
}
static const struct zz_pkt_io packet_io = {ethernet_packet_read, write_word, 0};
static void invalidate(void *context, unsigned slot, unsigned from, unsigned bytes)
{
    (void)context; assert(slot < 128);
    if (from == 32) {
        assert(!publish_step[slot] && bytes == (unsigned)packet_length[slot] + 4u - 32u);
        publish_step[slot] = 1;
    } else {
        assert(from == 0 && bytes == 32 && publish_step[slot] == 2);
        publish_step[slot] = 3; publishes[slot]++;
    }
}
static void header(void *context, unsigned slot, uint16_t length, uint16_t serial)
{
    (void)context; assert(publish_step[slot] == 1);
    assert(length == packet_length[slot] && serial == packet_serial[slot]);
    publish_step[slot] = 2;
}
static const struct zz_rx_publish_ops packet_publish = {invalidate, header};
/* EXACT_SERVICE_BODIES */
static void setup(unsigned first, unsigned backlog)
{
    zz_rx_lease_init(&packet_leases);
    packet_mode = packet_active = ethernet_hw_ready = running = ready = 1;
    packet_fault = rx_backpressure = 0;
    frames_backlog_read = first; frames_backlog = backlog; frames_backlog_reserved = 0;
    frames_dropped = allocations = writes = commits = pops = count = held = pop_failure = 0;
    memset(clears, 0, sizeof(clears)); memset(publishes, 0, sizeof(publishes));
    memset(publish_step, 0, sizeof(publish_step));
    for (unsigned i = 0; i < 128; i++) {
        packet_length[i] = 1514; packet_serial[i] = 2 + i; rx_backlog_csum[i] = i % 4;
    }
}
static void release(unsigned index, unsigned error)
{
    assert(!held && index < count);
    released_slot = queue[index].slot; released_cookie = queue[index].cookie;
    released_error = error; held = 1;
    memmove(&queue[index], &queue[index + 1], (count - index - 1) * sizeof(queue[0]));
    count--;
}
int main(void)
{
    setup(126, 8); frames_backlog_reserved = 64; rx_backpressure = 1;
    ethernet_packet_service_locked();
    assert(commits == 3 && packet_leases.count == 4 && packet_leases.offered_slot == 1);
    assert(allocations == 1 && !rx_backpressure);
    unsigned stalled_writes = writes;
    for (unsigned i = 0; i < 5; i++) ethernet_packet_service_locked();
    assert(writes == stalled_writes && publishes[1] == 1 && frames_backlog == 8);
    for (unsigned i = 0; i < 8; i++) {
        release(0, i == 3); ethernet_packet_service_locked();
        assert(!packet_fault && frames_backlog == 7 - i);
        assert(frames_backlog_read == (127 + i) % 128);
    }
    assert(commits == 8 && pops == 8 && !packet_leases.count && frames_dropped == 1);
    for (unsigned i = 0; i < 8; i++) {
        unsigned slot = (126 + i) % 128;
        assert(accepted[i].slot == slot && accepted[i].cookie == i + 1);
        assert(clears[slot] == 1 && publishes[slot] == 1);
    }
    puts("PASS actual service: wrap, bounded pending offer, publication, exact retirement and resume");

    setup(10, 3); ethernet_packet_service_locked();
    release(1, 0); ethernet_packet_service_locked();
    assert(!packet_fault && frames_backlog == 3 && !clears[11]);
    release(0, 0); ethernet_packet_service_locked();
    assert(frames_backlog == 1 && frames_backlog_read == 12 && clears[10] == 1 && clears[11] == 1);
    release(0, 0); ethernet_packet_service_locked(); assert(!frames_backlog);
    puts("PASS actual service: out-of-order release waits for contiguous ring retirement");

    for (unsigned failure = 1; failure <= 2; failure++) {
        setup(0, 1); ethernet_packet_service_locked(); release(0, 0);
        pop_failure = failure; rx_backpressure = 1;
        ethernet_packet_service_locked();
        assert(packet_fault && frames_backlog == 1 && !clears[0] && !pops && held);
        assert(packet_leases.state[0] == ZZ_RX_RELEASED && zz_rx_lease_pinned(&packet_leases, 0));
        assert(!allocations && ethernet_get_rx_status() == 0x8000);
        unsigned fault_writes = writes; ethernet_packet_service_locked(); assert(writes == fault_writes);
    }
    puts("PASS actual service: rejected/ambiguous POP pins RELEASED slot and hides readiness");

    setup(0, 1); ethernet_packet_service_locked(); release(0, 0); released_cookie++;
    ethernet_packet_service_locked();
    assert(packet_fault && !pops && !clears[0] && packet_leases.state[0] == ZZ_RX_OWNED);
    puts("PASS actual service: wrong release cookie faults without reuse");

    setup(0, 120); packet_length[0] = 13; rx_backpressure = 1;
    ethernet_packet_service_locked();
    assert(packet_fault && frames_backlog == 120 && !commits && !publishes[0] && !allocations);
    assert(ethernet_get_rx_status() == 0x8000); /* ready=0 does not mean DDR backlog=0. */
    puts("PASS actual service: invalid metadata reproduces fault-hidden full DDR backlog");

    for (unsigned gate = 0; gate < 5; gate++) {
        setup(0, 8); rx_backpressure = 1;
        if (gate == 0) packet_mode = 0;
        if (gate == 1) packet_active = 0;
        if (gate == 2) packet_fault = 1;
        if (gate == 3) ethernet_hw_ready = 0;
        if (gate == 4) running = 0;
        ethernet_packet_service_locked();
        assert(!writes && !allocations && frames_backlog == 8 && rx_backpressure);
        if (gate == 4) assert(packet_fault);
    }
    setup(0, 40); frames_backlog_reserved = 64; rx_backpressure = 1;
    ethernet_packet_service_locked(); assert(!allocations && rx_backpressure);
    puts("PASS actual service: stopped/fault/not-ready gates and low-watermark admission");
    return 0;
}
