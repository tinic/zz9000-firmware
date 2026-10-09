/* SPDX-License-Identifier: MIT
 * Offline ARM integration helper; not included in a firmware build.
 * Caller serializes ALL operations against GEM IRQs and transport consumers.
 * See test/eth_packet_window/ARM_CONTRACT.md before integrating.
 */
#ifndef ZZ_ETH_RX_LEASE_H
#define ZZ_ETH_RX_LEASE_H

#include <stdint.h>
#include <string.h>

#define ZZ_RX_SLOTS 128u
#define ZZ_RX_NO_OFFER ZZ_RX_SLOTS
#define ZZ_RX_CORE_DRAINED 1u
#define ZZ_RX_LINKS_DRAINED 2u
#define ZZ_RX_GEM_QUIESCED 4u
#define ZZ_RX_HOST_QUIESCED 8u
#define ZZ_RX_FLUSH_FENCE 15u

struct zz_rx_descriptor {
    uint32_t cookie;
    uint16_t length, serial;
    uint8_t slot, csum;
};

enum zz_rx_lease_state {
    ZZ_RX_FREE, ZZ_RX_OFFERED, ZZ_RX_OWNED, ZZ_RX_RELEASED
};

struct zz_rx_lease {
    struct zz_rx_descriptor descriptor[ZZ_RX_SLOTS];
    uint8_t state[ZZ_RX_SLOTS], error[ZZ_RX_SLOTS], order[ZZ_RX_SLOTS];
    uint16_t head, count, offered_slot;
    uint32_t next_cookie;
    uint8_t flushing;
};

/* Requires the live STRONGLY_ORDERED RX_BACKLOG mapping: header stores reach
 * DDR directly. Pure invalidation is not safe for a dirty cacheable header.
 * Each callback completes synchronously, including the required cache sync/DSB.
 * The adapter must preserve ethernet_backlog_slot_publish_from semantics.
 */
struct zz_rx_publish_ops {
    void (*invalidate)(void *context, unsigned slot, unsigned from, unsigned bytes);
    void (*header)(void *context, unsigned slot, uint16_t length, uint16_t serial);
};

/* Cold start only, after GEM, host, FPGA and transport have a common reset fence.
 * Never call this to implement a logical reset: that would reuse old cookies.
 */
static inline void zz_rx_lease_init(struct zz_rx_lease *p)
{
    memset(p, 0, sizeof(*p));
    p->offered_slot = ZZ_RX_NO_OFFER;
    p->next_cookie = 1;
}

static inline int zz_rx_lease_pinned(const struct zz_rx_lease *p, unsigned slot)
{
    return slot >= ZZ_RX_SLOTS || p->state[slot] != ZZ_RX_FREE;
}

/* Stop admission and initiate the full session fence before cookie reuse. */
static inline int zz_rx_lease_rollover_needed(const struct zz_rx_lease *p)
{
    return p->next_cookie == 0;
}

/* Read-only staging record. Copy it atomically into the eventual transport;
 * retain it and all backing DDR bytes until transport acceptance or flush fence.
 */
static inline const struct zz_rx_descriptor *zz_rx_lease_offer(const struct zz_rx_lease *p)
{
    if (p->flushing || p->offered_slot == ZZ_RX_NO_OFFER)
        return 0;
    return &p->descriptor[p->offered_slot];
}

/* Called in completed-ring order, only after DMA completion, once per slot.
 * This helper overlays the existing ring: it does not allocate/rearm GEM BDs.
 * No descriptor is visible before payload/header publication has completed.
 */
static inline int zz_rx_lease_prepare(struct zz_rx_lease *p, unsigned slot,
                                     unsigned length, unsigned serial, unsigned csum,
                                     const struct zz_rx_publish_ops *ops, void *context)
{
    struct zz_rx_descriptor d;
    if (p->flushing || p->offered_slot != ZZ_RX_NO_OFFER ||
        p->count == ZZ_RX_SLOTS || zz_rx_lease_pinned(p, slot) ||
        p->next_cookie == 0 || length < 14 || length > 2044 ||
        serial < 2 || serial > 65535 || csum > 3 ||
        !ops || !ops->invalidate || !ops->header)
        return 0;

    /* The first cache line includes header and the first 28 payload bytes. */
    if (length + 4 > 32)
        ops->invalidate(context, slot, 32, length + 4 - 32);
    ops->header(context, slot, (uint16_t)length, (uint16_t)serial);
    ops->invalidate(context, slot, 0, 32);

    memset(&d, 0, sizeof(d));
    d.cookie = p->next_cookie++;
    d.slot = (uint8_t)slot;
    d.length = (uint16_t)length;
    d.serial = (uint16_t)serial;
    d.csum = (uint8_t)csum;
    p->descriptor[slot] = d;
    p->state[slot] = ZZ_RX_OFFERED;
    p->error[slot] = 0;
    p->order[(p->head + p->count) % ZZ_RX_SLOTS] = (uint8_t)slot;
    p->count++;
    p->offered_slot = (uint16_t)slot;
    return 1;
}

/* Called exactly once after the transport has durably accepted the WHOLE record.
 * A mailbox store without its commit/acceptance handshake is not acceptance.
 */
static inline int zz_rx_lease_accept(struct zz_rx_lease *p)
{
    if (!zz_rx_lease_offer(p))
        return 0;
    p->state[p->offered_slot] = ZZ_RX_OWNED;
    p->offered_slot = ZZ_RX_NO_OFFER;
    return 1;
}

/* Host ACK/fill completion must NOT call this. Only an accepted FPGA release
 * record can retire a lease. Error releases free ownership by the same rules.
 */
static inline int zz_rx_lease_release(struct zz_rx_lease *p, unsigned slot,
                                     uint32_t cookie, unsigned error)
{
    if (p->flushing || slot >= ZZ_RX_SLOTS || error > 1 ||
        p->state[slot] != ZZ_RX_OWNED || p->descriptor[slot].cookie != cookie)
        return 0;
    p->state[slot] = ZZ_RX_RELEASED;
    p->error[slot] = (uint8_t)error;
    return 1;
}

/* Only the contiguous released prefix may advance the existing ring's head.
 * Caller must clear exactly this slot and decrement backlog once, inside the
 * same IRQ-excluded critical section. Do not use legacy serial/bare ACK here.
 */
static inline int zz_rx_lease_retire(struct zz_rx_lease *p,
                                    struct zz_rx_descriptor *d, unsigned *error)
{
    unsigned slot;
    if (p->flushing || !p->count || !d || !error)
        return 0;
    slot = p->order[p->head];
    if (p->state[slot] != ZZ_RX_RELEASED)
        return 0;
    *d = p->descriptor[slot];
    *error = p->error[slot];
    p->state[slot] = ZZ_RX_FREE;
    p->head = (p->head + 1) % ZZ_RX_SLOTS;
    p->count--;
    return 1;
}

static inline void zz_rx_lease_flush_begin(struct zz_rx_lease *p)
{
    p->flushing = 1;
}

/* Fence bits are caller assertions of completed physical handshakes, NOT waits.
 * FPGA flush_done alone cannot cancel queued transport records or GEM writes.
 * Keep all leases pinned until every part of the coordinated reset has finished.
 */
static inline int zz_rx_lease_flush_finish(struct zz_rx_lease *p, unsigned fence)
{
    uint32_t next_cookie;
    if (!p->flushing || (fence & ZZ_RX_FLUSH_FENCE) != ZZ_RX_FLUSH_FENCE)
        return 0;
    next_cookie = p->next_cookie;
    zz_rx_lease_init(p);
    /* A COMPLETE session fence proves no old host/transport command can arrive.
     * Only here may exhausted cookies restart; skipping pinned values alone
     * cannot protect against a stale command surviving an entire cookie cycle.
     */
    p->next_cookie = next_cookie ? next_cookie : 1;
    return 1;
}
#endif
