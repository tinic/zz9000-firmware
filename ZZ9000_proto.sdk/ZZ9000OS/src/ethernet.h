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
void ethernet_task();
void ethernet_reset_for_amiga();

#define FRAME_MAX_BACKLOG 128

/*
 * Receive descriptors armed at once: the frames the GEM can land without
 * the ARM's help.  A sender on the same gigabit switch puts a whole TCP
 * window on the wire back to back, 12 us a frame, and every frame past the
 * armed count is lost in the GEM before anything here counts it: with 32,
 * a 47 KB window lost frames 33-35 of every burst (measured on an A3000,
 * 25-275 TCP retransmissions in ten seconds, nothing in the error
 * counters).  The BD ring region at RX_BD_LIST_START_ADDRESS has room.
 */
#define RXBD_CNT       64	/* Number of RxBDs to use */
#define TXBD_CNT       2	/* Number of TxBDs to use */

#endif
