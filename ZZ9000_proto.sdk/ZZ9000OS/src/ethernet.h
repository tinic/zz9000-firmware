/*
 * MNT ZZ9000 Amiga Graphics and Coprocessor Card Operating System (ZZ9000OS)
 *
 * Copyright (C) 2019-2026, Lucie L. Hartmann <lucie@mntre.com>
 *                          MNT Research GmbH, Berlin
 *                          https://mntre.com
 *
 * More Info: https://mntre.com/zz9000
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 * GNU General Public License v3.0 or later
 *
 * https://spdx.org/licenses/GPL-3.0-or-later.html
 *
*/

#ifndef ETHERNET_H_
#define ETHERNET_H_

int ethernet_init();
u16 ethernet_send_frame(u16 frame_size);
int ethernet_receive_frame(u16 acked_serial);
u32 get_frames_received();
uint8_t* ethernet_get_mac_address_ptr();
void ethernet_update_mac_address();
uint8_t* ethernet_current_receive_ptr();
int ethernet_get_backlog();
u16 ethernet_get_rx_status();
u16 ethernet_get_rx_stats();
/* Detection only: count of FAILED XEmacPs_BdRingFree OPERATIONS on the RX
 * ring since the last host-state reset -- not lost BDs, and not a rate.
 * Each failure strands that call's BDs outside the free list, which is
 * invisible in every other counter. Because the receive path frees every
 * reclaimed BD in one call, a single failure can strand the entire ring, so
 * any non-zero value is significant and the magnitude is not a severity
 * scale. Bounded by RXBD_CNT under the current ownership/reset model;
 * saturates at 0xffff defensively, since a wrap to 0 would read as
 * "no failures". Zero is likewise not proof of RX health: through the
 * register it is indistinguishable from firmware that lacks the
 * diagnostic. */
u16 ethernet_get_rx_bdfree_failures();
/* The 32-bit word REG_ZZ_ETH_DIAG reads back: count in the HIGH 16 bits. */
u32 ethernet_get_rx_diag_word();
void ethernet_task();
void ethernet_reset_for_amiga();

#define FRAME_MAX_BACKLOG 128

#define RXBD_CNT       32	/* Number of RxBDs to use */
#define TXBD_CNT       2	/* Number of TxBDs to use */

#endif
