/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef ETH_PACKET_WINDOW_H
#define ETH_PACKET_WINDOW_H

/* Versioned live integration proposal; this magic promises the complete fence
 * and snapshot-cookie host protocol, not merely the presence of packet RAM. */
#define ETH_PACKET_CAP_OFFSET 0x20u
#define ETH_PACKET_CAP_MAGIC 0x5a505731u
#define ETH_PACKET_FENCE_OFFSET 0x24u
#define ETH_PACKET_HOST_DRAINED 1u
#define ETH_PACKET_LINK_DRAINED 2u
#define ETH_PACKET_READY 4u
#define ETH_PACKET_FENCE_STOP 1u
#define ETH_PACKET_FENCE_RESUME 2u
#define ETH_PACKET_MAILBOX_OFFSET 0x40u

#include "../../../experimental/zz_eth_packet_transport.h"
#endif
