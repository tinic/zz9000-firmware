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

/*
 * ASYNCHRONOUS TRANSMIT (REG_ZZ_ETH_TX with bit 15 set).
 *
 * ethernet_send_frame() holds the Zorro bus -- the 68k stalls in its write
 * cycle -- until the GEM has sent, 100 us to 1 ms per frame (a usleep(100)
 * poll).  Measured on an A3000 that was 16% of the CPU at 4.6 Mbit/s of TCP
 * receive, spent on ACKs.  A driver that sets bit 15 of the length word
 * instead names one of the four 2 KB slots of the TX window in bits 12..11
 * and gets the bus back as soon as the BD is queued; it learns of
 * completion from REG_ZZ_ETH_TX_STATUS: bit 15 says the firmware has this
 * path at all (an older firmware reads the register as 0), bits 14..0 count
 * frames finished -- sent, or dropped for want of a BD, which is what the
 * driver cannot tell apart and need not: the slot is free either way.
 * A length word without bit 15 is the old synchronous send, unchanged, so
 * ZZ9000Net.device keeps working.
 */
#define ETH_TX_ASYNC        0x8000u
#define ETH_TX_SLOT_SHIFT   11
#define ETH_TX_SLOT_MASK    0x3u
#define ETH_TX_LEN_MASK     0x7ffu
#define ETH_TX_STATUS_PRESENT 0x8000u
#define ETH_TX_STATUS_COUNT   0x7fffu
void ethernet_send_frame_async(u16 slot, u16 frame_size);
u16 ethernet_get_tx_status();
/* REG_ZZ_ETH_ERRORS: GEM receive FIFO overruns << 16 | error interrupts */
u32 ethernet_get_errors();
int ethernet_receive_frame(u16 acked_serial);
u32 get_frames_received();
uint8_t* ethernet_get_mac_address_ptr();
void ethernet_update_mac_address();
uint8_t* ethernet_current_receive_ptr();
int ethernet_get_backlog();
u16 ethernet_get_rx_status();
u16 ethernet_get_rx_stats();
/* REG_ZZ_ETH_RX_META: presence plus the current BD's GEM checksum verdict. */
#define ETH_RX_META_PRESENT 0x8000u
#define ETH_RX_META_MASK    0x0003u
#define ETH_RX_META_NONE    0u
#define ETH_RX_META_IP      1u
#define ETH_RX_META_TCP     2u
#define ETH_RX_META_UDP     3u
u16 ethernet_get_rx_meta();
void ethernet_task();
void ethernet_reset_for_amiga();

#define FRAME_MAX_BACKLOG 128

/*
 * Receive descriptors armed at once: the frames the GEM lands without the
 * ARM's help.  A sender on the same gigabit switch puts a whole TCP window
 * on the wire back to back, 12 us a frame, and every frame past the armed
 * count is lost in the GEM before anything here can count it: with 32, a
 * 47 KB window lost frames 33, 34 and 35 of every burst (AmiNetXDuo
 * anxzz9000.device, A3000, 25 retransmissions in ten seconds; with the
 * window sized to the ring, 275).  64 covers the window the driver now
 * advertises against ETH_BACKLOG_HIGH_WATERMARK.
 */
#define RXBD_CNT       64	/* Number of RxBDs to use */
#define TXBD_CNT       4	/* Number of TxBDs to use: the four slots of the TX window */

#endif
