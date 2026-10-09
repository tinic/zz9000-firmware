/* SPDX-License-Identifier: MIT */
#include <stdio.h>
#include <stdlib.h>
#include "../../experimental/zz_eth_rx_lease.h"

#define CHECK(c, message) do { if (!(c)) { \
    fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, message); exit(1); \
} } while (0)

struct publication {
    struct zz_rx_lease *leases;
    unsigned step, length, serial, slot;
};

static void invalidate(void *context, unsigned slot, unsigned from, unsigned bytes)
{
    struct publication *p = context;
    CHECK(!zz_rx_lease_offer(p->leases), "descriptor visible before publication finished");
    CHECK(slot == p->slot, "publication used wrong slot");
    if (from == 32) {
        CHECK(p->step == 0 && p->length > 28, "payload publication order");
        CHECK(bytes == p->length + 4 - 32, "payload publication extent");
        p->step = 1;
    } else {
        CHECK(from == 0 && bytes == 32 && p->step == 2, "header publication order");
        p->step = 3;
    }
}

static void header(void *context, unsigned slot, uint16_t length, uint16_t serial)
{
    struct publication *p = context;
    CHECK(!zz_rx_lease_offer(p->leases), "descriptor visible before header write");
    CHECK(p->step == (p->length > 28 ? 1u : 0u), "header written before payload publication");
    CHECK(slot == p->slot && length == p->length && serial == p->serial,
          "header metadata mismatch");
    p->step = 2;
}

static const struct zz_rx_publish_ops ops = { invalidate, header };

static uint32_t prepare(struct zz_rx_lease *p, unsigned slot, unsigned length, unsigned serial)
{
    struct publication publication = { p, 0, length, serial, slot };
    const struct zz_rx_descriptor *d;
    CHECK(zz_rx_lease_prepare(p, slot, length, serial, 3, &ops, &publication), "prepare failed");
    CHECK(publication.step == 3, "publication incomplete");
    d = zz_rx_lease_offer(p);
    CHECK(d && d->slot == slot && d->length == length && d->serial == serial && d->csum == 3,
          "offered metadata mismatch");
    CHECK(zz_rx_lease_pinned(p, slot), "offered slot not pinned");
    return d->cookie;
}

static void retire(struct zz_rx_lease *p, unsigned slot, uint32_t cookie, unsigned expected_error)
{
    struct zz_rx_descriptor d;
    unsigned error;
    CHECK(zz_rx_lease_retire(p, &d, &error), "retirement failed");
    CHECK(d.slot == slot && d.cookie == cookie && error == expected_error, "wrong retirement");
    CHECK(!zz_rx_lease_pinned(p, slot), "retired slot remains pinned");
}

static void publication_and_stall(void)
{
    struct zz_rx_lease p;
    struct publication publication = { &p, 0, 60, 2, 0 };
    struct zz_rx_descriptor saved;
    uint32_t cookie;
    zz_rx_lease_init(&p);
    CHECK(!zz_rx_lease_prepare(&p, 128, 60, 2, 0, &ops, &publication), "invalid slot accepted");
    CHECK(!zz_rx_lease_prepare(&p, 0, 13, 2, 0, &ops, &publication), "short frame accepted");
    CHECK(!zz_rx_lease_prepare(&p, 0, 2045, 2, 0, &ops, &publication), "oversized frame accepted");
    CHECK(!zz_rx_lease_prepare(&p, 0, 60, 1, 0, &ops, &publication), "reserved serial accepted");
    CHECK(!zz_rx_lease_prepare(&p, 0, 60, 65536, 0, &ops, &publication), "serial truncated");
    CHECK(!zz_rx_lease_prepare(&p, 0, 60, 2, 4, &ops, &publication), "checksum verdict truncated");
    CHECK(!zz_rx_lease_prepare(&p, 0, 60, 2, 0, 0, &publication), "missing publication ops accepted");
    CHECK(publication.step == 0 && p.count == 0 && p.next_cookie == 1, "invalid input changed ownership");
    cookie = prepare(&p, 0, 2044, 65535);
    saved = *zz_rx_lease_offer(&p);
    for (unsigned i = 0; i != 100; ++i) {
        CHECK(!zz_rx_lease_prepare(&p, 1, 60, 2, 0, &ops, &publication), "stalled offer overwritten");
        CHECK(memcmp(&saved, zz_rx_lease_offer(&p), sizeof(saved)) == 0, "stalled descriptor changed");
        CHECK(!zz_rx_lease_release(&p, 0, cookie, 0), "unaccepted descriptor released");
    }
    CHECK(zz_rx_lease_accept(&p), "accept failed");
    CHECK(!zz_rx_lease_accept(&p), "double accept succeeded");
    CHECK(!zz_rx_lease_prepare(&p, 0, 60, 2, 0, &ops, &publication), "owned slot republished");
    CHECK(zz_rx_lease_release(&p, 0, cookie, 0), "release failed");
    retire(&p, 0, cookie, 0);
    for (unsigned length = 14; length <= 29; ++length) {
        cookie = prepare(&p, 0, length, 2);
        CHECK(zz_rx_lease_accept(&p), "small accept failed");
        CHECK(zz_rx_lease_release(&p, 0, cookie, 0), "small release failed");
        retire(&p, 0, cookie, 0);
    }
    puts("PASS publication ordering, first-line boundary, validation and immutable stalled offer");
}

static void release_order(void)
{
    struct zz_rx_lease p;
    struct zz_rx_descriptor d;
    unsigned error;
    uint32_t a, b, c;
    zz_rx_lease_init(&p);
    a = prepare(&p, 126, 1500, 65534); CHECK(zz_rx_lease_accept(&p), "accept A");
    b = prepare(&p, 127, 61, 65535); CHECK(zz_rx_lease_accept(&p), "accept B");
    CHECK(!zz_rx_lease_retire(&p, &d, &error), "unreleased packet retired");
    CHECK(!zz_rx_lease_release(&p, 126, b, 0), "crossed cookie accepted");
    CHECK(!zz_rx_lease_release(&p, 0, a, 0), "crossed slot accepted");
    CHECK(!zz_rx_lease_release(&p, 126, a, 2), "bad release status accepted");
    CHECK(zz_rx_lease_release(&p, 127, b, 1), "error release rejected");
    CHECK(!zz_rx_lease_release(&p, 127, b, 1), "duplicate release accepted");
    CHECK(!zz_rx_lease_retire(&p, &d, &error), "out-of-order release advanced ring");
    /* A freed FPGA bank can accept C while the ARM still holds older releases. */
    c = prepare(&p, 0, 62, 2); CHECK(zz_rx_lease_accept(&p), "accept C");
    CHECK(p.count == 3 && zz_rx_lease_pinned(&p, 126) && zz_rx_lease_pinned(&p, 127),
          "release backpressure lost DDR ownership");
    CHECK(zz_rx_lease_release(&p, 126, a, 0), "release A");
    retire(&p, 126, a, 0); retire(&p, 127, b, 1);
    CHECK(!zz_rx_lease_release(&p, 126, a, 0), "retired release replay accepted");
    CHECK(!zz_rx_lease_retire(&p, &d, &error), "C retired without release");
    CHECK(zz_rx_lease_release(&p, 0, c, 0), "release C"); retire(&p, 0, c, 0);
    CHECK(p.count == 0, "lease count leaked");
    puts("PASS exact release identity, error/duplicate/reordered releases and contiguous retirement");
}

static void reset_fence(void)
{
    struct zz_rx_lease p;
    struct zz_rx_descriptor d;
    struct publication publication = { &p, 0, 60, 2, 3 };
    unsigned error;
    uint32_t a, b, fresh;
    zz_rx_lease_init(&p);
    a = prepare(&p, 1, 60, 2); CHECK(zz_rx_lease_accept(&p), "accept A");
    b = prepare(&p, 2, 60, 3); /* pending transport offer, not accepted */
    CHECK(!zz_rx_lease_flush_finish(&p, ZZ_RX_FLUSH_FENCE), "flush finished without begin");
    zz_rx_lease_flush_begin(&p);
    CHECK(!zz_rx_lease_offer(&p) && !zz_rx_lease_accept(&p), "new descriptor during flush");
    CHECK(!zz_rx_lease_prepare(&p, 3, 60, 2, 0, &ops, &publication), "prepare during flush");
    CHECK(!zz_rx_lease_release(&p, 1, a, 0), "late release changed cancelling ring");
    CHECK(!zz_rx_lease_retire(&p, &d, &error), "retirement during flush");
    for (unsigned fence = 0; fence != ZZ_RX_FLUSH_FENCE; ++fence) {
        CHECK(!zz_rx_lease_flush_finish(&p, fence), "incomplete flush fence reclaimed slots");
        CHECK(p.count == 2 && zz_rx_lease_pinned(&p, 1) && zz_rx_lease_pinned(&p, 2),
              "flush before drain lost ownership");
    }
    CHECK(zz_rx_lease_flush_finish(&p, ZZ_RX_FLUSH_FENCE), "complete flush failed");
    CHECK(p.count == 0 && p.next_cookie > b, "flush reused cookie sequence");
    fresh = prepare(&p, 1, 60, 2); CHECK(zz_rx_lease_accept(&p), "new epoch accept");
    CHECK(!zz_rx_lease_release(&p, 1, a, 0), "pre-reset release consumed new slot");
    CHECK(zz_rx_lease_release(&p, 1, fresh, 0), "fresh release rejected"); retire(&p, 1, fresh, 0);
    puts("PASS pending/accepted leases survive partial reset fences and reject stale releases");
}

static void ring_and_cookie_wrap(void)
{
    struct zz_rx_lease p;
    uint32_t cookies[ZZ_RX_SLOTS], last;
    struct publication publication = { &p, 0, 60, 2, 0 };
    zz_rx_lease_init(&p);
    for (unsigned round = 0; round != 3; ++round) {
        for (unsigned slot = 0; slot != ZZ_RX_SLOTS; ++slot) {
            cookies[slot] = prepare(&p, slot, 60, 2);
            CHECK(zz_rx_lease_accept(&p), "ring accept");
        }
        CHECK(p.count == ZZ_RX_SLOTS, "full ledger count");
        CHECK(!zz_rx_lease_prepare(&p, 0, 60, 2, 0, &ops, &publication), "full ledger overwritten");
        for (unsigned slot = ZZ_RX_SLOTS; slot-- != 0; )
            CHECK(zz_rx_lease_release(&p, slot, cookies[slot], 0), "ring release");
        for (unsigned slot = 0; slot != ZZ_RX_SLOTS; ++slot)
            retire(&p, slot, cookies[slot], 0);
        CHECK(p.count == 0, "wrapped ring count leaked");
    }
    p.next_cookie = UINT32_MAX; /* boundary injection, not an integration API */
    last = prepare(&p, 0, 60, 2); CHECK(last == UINT32_MAX, "last cookie truncated");
    CHECK(zz_rx_lease_accept(&p), "last cookie accept");
    CHECK(zz_rx_lease_release(&p, 0, last, 0), "last cookie release"); retire(&p, 0, last, 0);
    CHECK(zz_rx_lease_rollover_needed(&p), "cookie exhaustion not signalled");
    CHECK(!zz_rx_lease_prepare(&p, 0, 60, 2, 0, &ops, &publication), "exhausted cookies wrapped");
    zz_rx_lease_flush_begin(&p);
    for (unsigned fence = 0; fence != ZZ_RX_FLUSH_FENCE; ++fence) {
        CHECK(!zz_rx_lease_flush_finish(&p, fence), "cookie rollover before complete fence");
        CHECK(zz_rx_lease_rollover_needed(&p), "cookie reused before all old commands drained");
    }
    CHECK(zz_rx_lease_flush_finish(&p, ZZ_RX_FLUSH_FENCE), "exhausted-cookie flush");
    CHECK(!zz_rx_lease_rollover_needed(&p), "completed fence did not recover exhausted cookies");
    cookies[0] = prepare(&p, 0, 60, 2);
    CHECK(cookies[0] == 1 && zz_rx_lease_accept(&p), "fenced cookie rollover failed");
    CHECK(!zz_rx_lease_release(&p, 0, last, 0), "last pre-fence cookie consumed fresh lease");
    CHECK(zz_rx_lease_release(&p, 0, cookies[0], 0), "post-rollover release failed");
    retire(&p, 0, cookies[0], 0);
    puts("PASS full ledger/backpressure, ring wrap and cookie rollover only after full session fence");
}

int main(void)
{
    publication_and_stall();
    release_order();
    reset_fence();
    ring_and_cookie_wrap();
    puts("ALL PASS: 4 ARM lease groups (offline helper, not hardware validation)");
    return 0;
}
