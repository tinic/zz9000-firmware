/* SPDX-License-Identifier: MIT */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../../experimental/zz_eth_packet_transport.h"

struct bus {
    uint32_t status, result, cookie, meta, stage[4];
    unsigned writes, commits, pops, reject_word, corrupt_word;
};
static uint32_t read_word(void *ctx, unsigned word)
{
    struct bus *b = ctx;
    switch (word) {
    case ZZ_PKT_STATUS: return b->status;
    case ZZ_PKT_RESULT: return b->result;
    case ZZ_PKT_RELEASE_COOKIE: return b->cookie;
    case ZZ_PKT_RELEASE_META: return b->meta;
    default: assert(0); return 0;
    }
}
static void write_word(void *ctx, unsigned word, uint32_t value)
{
    struct bus *b = ctx;
    b->writes++;
    b->result = 0x100u | word << 4;
    if (b->corrupt_word == word) { b->result = 0; return; }
    if (b->reject_word == word) { b->result |= 1; return; }
    if (word >= ZZ_PKT_COOKIE && word <= ZZ_PKT_SLOT) b->stage[word] = value;
    else if (word == ZZ_PKT_COMMIT) {
        assert(value == b->stage[1]); b->commits++;
    } else if (word == ZZ_PKT_POP) {
        assert(value == b->cookie); b->pops++; b->status &= ~ZZ_PKT_RELEASE_HELD;
    } else assert(0);
}
static void invalidate(void *ctx, unsigned slot, unsigned from, unsigned bytes)
{ (void)ctx; (void)slot; (void)from; (void)bytes; }
static void header(void *ctx, unsigned slot, uint16_t length, uint16_t serial)
{ (void)ctx; (void)slot; (void)length; (void)serial; }
static const struct zz_rx_publish_ops publish = {invalidate, header};
static void setup(struct zz_rx_lease *p, struct bus *b)
{
    zz_rx_lease_init(p); memset(b, 0, sizeof(*b));
    b->status = ZZ_PKT_RUNNING; b->reject_word = b->corrupt_word = 99;
    assert(zz_rx_lease_prepare(p, 127, 1514, 65535, 3, &publish, 0));
}
int main(void)
{
    struct zz_rx_lease p;
    struct bus b;
    struct zz_pkt_io io = {read_word, write_word, &b};
    struct zz_rx_descriptor d;
    unsigned error;
    setup(&p, &b);
    b.status |= ZZ_PKT_PENDING;
    assert(zz_pkt_submit(&p, &io) == 0 && b.writes == 0 && p.state[127] == ZZ_RX_OFFERED);
    b.status &= ~ZZ_PKT_PENDING;
    assert(zz_pkt_submit(&p, &io) == 1 && b.commits == 1 && p.state[127] == ZZ_RX_OWNED);
    assert(b.stage[2] == 0xffff05eau && b.stage[3] == 0x1ffu);
    assert(zz_pkt_submit(&p, &io) == 0 && b.commits == 1);
    b.status |= ZZ_PKT_RELEASE_HELD; b.cookie = 1; b.meta = 127 | 128;
    assert(zz_pkt_release(&p, &io) == 1 && b.pops == 1);
    assert(zz_rx_lease_retire(&p, &d, &error) && d.slot == 127 && error == 1);
    assert(zz_pkt_release(&p, &io) == 0 && b.pops == 1);
    puts("PASS pressure, explicit encoding, exactly-once acceptance and error release");

    for (unsigned word = ZZ_PKT_COOKIE; word <= ZZ_PKT_COMMIT; ++word) {
        setup(&p, &b); b.reject_word = word;
        assert(zz_pkt_submit(&p, &io) == 0 && b.commits == 0 && p.state[127] == ZZ_RX_OFFERED);
        b.reject_word = 99;
        assert(zz_pkt_submit(&p, &io) == 1 && b.commits == 1);
        setup(&p, &b); b.corrupt_word = word;
        assert(zz_pkt_submit(&p, &io) == -1 && p.state[127] == ZZ_RX_OFFERED);
    }
    puts("PASS rejected staging/commit retry and ambiguous result retain offer");

    setup(&p, &b); assert(zz_pkt_submit(&p, &io) == 1);
    b.status |= ZZ_PKT_RELEASE_HELD; b.cookie = 2; b.meta = 127;
    assert(zz_pkt_release(&p, &io) == -1 && b.pops == 0 && p.state[127] == ZZ_RX_OWNED);
    b.cookie = 1; b.meta |= 0x100;
    assert(zz_pkt_release(&p, &io) == -1 && b.pops == 0);
    b.meta = 127; b.reject_word = ZZ_PKT_POP;
    assert(zz_pkt_release(&p, &io) == -1 && b.pops == 0 && zz_rx_lease_pinned(&p, 127));
    assert(p.state[127] == ZZ_RX_RELEASED); /* caller must fence, never retire */
    puts("PASS wrong identity, reserved release bits and failed POP keep DDR pinned");

    setup(&p, &b); assert(zz_pkt_submit(&p, &io) == 1);
    b.status |= ZZ_PKT_RELEASE_HELD; b.cookie = 1; b.meta = 127;
    zz_rx_lease_flush_begin(&p);
    assert(zz_pkt_release(&p, &io) == 0 && b.pops == 0);
    assert(zz_pkt_submit(&p, &io) == 0);
    assert(!zz_rx_lease_flush_finish(&p, ZZ_RX_CORE_DRAINED));
    assert(zz_rx_lease_pinned(&p, 127));
    assert(zz_rx_lease_flush_finish(&p, ZZ_RX_FLUSH_FENCE));
    assert(p.next_cookie == 2);
    puts("PASS reset excludes late normal release and preserves cookie generation");
    return 0;
}
