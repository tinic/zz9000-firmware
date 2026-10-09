/* SPDX-License-Identifier: MIT
 * Serialized ARM mailbox operations. Callers provide ordered, completed MMIO.
 * No MMIO address, IRQ lock, cache maintenance or reset fence is implied here.
 */
#ifndef ZZ_ETH_PACKET_TRANSPORT_H
#define ZZ_ETH_PACKET_TRANSPORT_H
#include "zz_eth_rx_lease.h"

#define ZZ_PKT_STATUS 0u
#define ZZ_PKT_COOKIE 1u
#define ZZ_PKT_META 2u
#define ZZ_PKT_SLOT 3u
#define ZZ_PKT_COMMIT 4u
#define ZZ_PKT_RELEASE_COOKIE 5u
#define ZZ_PKT_RELEASE_META 6u
#define ZZ_PKT_POP 7u
#define ZZ_PKT_CONTROL 8u
#define ZZ_PKT_RESULT 9u
#define ZZ_PKT_RUNNING 1u
#define ZZ_PKT_HALTED 4u
#define ZZ_PKT_DRAIN_COMPLETE 8u
#define ZZ_PKT_PENDING 16u
#define ZZ_PKT_RELEASE_HELD 32u

struct zz_pkt_io {
    uint32_t (*read)(void *context, unsigned word);
    void (*write)(void *context, unsigned word, uint32_t value);
    void *context;
};

/* -1 = ambiguous/wrong result, 0 = explicit rejection, 1 = accepted. */
static inline int zz_pkt_write(const struct zz_pkt_io *io, unsigned word,
                               uint32_t value)
{
    uint32_t result;
    io->write(io->context, word, value);
    result = io->read(io->context, ZZ_PKT_RESULT);
    if ((result & 0x1f0u) != (0x100u | (word << 4)))
        return -1;
    return (result & 1u) ? 0 : 1;
}

/* 1 accepted; 0 pressure/stopped; -1 ownership/result fault. The offer stays
 * pinned on every failure. Caller must stop normal retirement after -1. */
static inline int zz_pkt_submit(struct zz_rx_lease *lease,
                                const struct zz_pkt_io *io)
{
    const struct zz_rx_descriptor *d = zz_rx_lease_offer(lease);
    uint32_t status;
    int result;
    if (!d)
        return 0;
    status = io->read(io->context, ZZ_PKT_STATUS);
    if (!(status & ZZ_PKT_RUNNING) || (status & ZZ_PKT_PENDING))
        return 0;
    result = zz_pkt_write(io, ZZ_PKT_COOKIE, d->cookie);
    if (result != 1) return result;
    result = zz_pkt_write(io, ZZ_PKT_META, ((uint32_t)d->serial << 16) | d->length);
    if (result != 1) return result;
    result = zz_pkt_write(io, ZZ_PKT_SLOT, d->slot | ((uint32_t)d->csum << 7));
    if (result != 1) return result;
    result = zz_pkt_write(io, ZZ_PKT_COMMIT, d->cookie);
    if (result != 1) return result;
    return zz_rx_lease_accept(lease) ? 1 : -1;
}

/* Mark release, then POP, then permit caller to retire. On an unsuccessful POP
 * the RELEASED slot is STILL pinned; caller must not call lease_retire. The
 * operation is not retried blindly, since completion may have been ambiguous. */
static inline int zz_pkt_release(struct zz_rx_lease *lease,
                                 const struct zz_pkt_io *io)
{
    uint32_t status = io->read(io->context, ZZ_PKT_STATUS), cookie, meta;
    if (lease->flushing || !(status & ZZ_PKT_RUNNING) ||
        !(status & ZZ_PKT_RELEASE_HELD))
        return 0;
    cookie = io->read(io->context, ZZ_PKT_RELEASE_COOKIE);
    meta = io->read(io->context, ZZ_PKT_RELEASE_META);
    if (meta & ~0xffu)
        return -1;
    if (!zz_rx_lease_release(lease, meta & 0x7fu, cookie, (meta >> 7) & 1u))
        return -1;
    return zz_pkt_write(io, ZZ_PKT_POP, cookie) == 1 ? 1 : -1;
}
#endif
