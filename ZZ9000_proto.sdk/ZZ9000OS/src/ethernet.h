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

#define ETH_CONFIG_CAP_MULTICAST_HASH 0x0001
/* Read-side: firmware reports Ethernet link readiness in bit 8. */
#define ETH_CONFIG_CAP_LINK_STATE     0x0002
/* Set once PHY auto-negotiation has completed and the EMAC is running. */
#define ETH_CONFIG_LINK_READY         0x0100
#define ETH_CONFIG_HASH_SET            0x8000
#define ETH_CONFIG_HASH_CLEAR          0x4000
#define ETH_CONFIG_HASH_RESET          0x2000
#define ETH_CONFIG_HASH_INDEX          0x003f

enum {
	ETH_TASK_SETUP,
	ETH_TASK_NEGOTIATE,
	ETH_TASK_INIT,
	ETH_TASK_READY
};

extern int ethernet_task_state;
extern int ethernet_hw_ready;

int ethernet_init();
void ethernet_set_multicast_hash(u16 command);
u16 ethernet_get_multicast_config(void);
u32 ethernet_emac_base(void);
u32 ethernet_mac_lo_word(const uint8_t mac[6]);
u16 ethernet_zorro16(u32 word, u32 zaddr);
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

#define RXBD_CNT       32	/* Number of RxBDs to use */
#define TXBD_CNT       4	/* Number of TxBDs to use: the four slots of the TX window */

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
 * frames finished -- sent, or dropped for want of a BD, which the driver
 * cannot tell apart and need not: the slot is free either way.  A length
 * word without bit 15 is the old synchronous send, unchanged, so existing
 * drivers keep working.
 */
#define ETH_TX_ASYNC          0x8000u
#define ETH_TX_SLOT_SHIFT     11
#define ETH_TX_SLOT_MASK      0x3u
#define ETH_TX_LEN_MASK       0x7ffu
#define ETH_TX_STATUS_PRESENT 0x8000u
#define ETH_TX_STATUS_COUNT   0x7fffu
void ethernet_send_frame_async(u16 slot, u16 frame_size);
u16 ethernet_get_tx_status(void);

/*
 * REG_ZZ_ETH_RX_META: checksum capabilities plus the current RX verdict.
 *
 * Bit 15: the GEM's receive checksum offload is on, so bits 1..0 hold the
 * verdict for the frame presented in the RX window: 0 none, 1 IP header only,
 * 2 IP and TCP, 3 IP and UDP checked good (the GEM discards frames whose
 * checksum it found bad).  A driver can then skip summing the payload.
 * Bit 14: transmit checksum insertion is on; a driver may zero the TCP/UDP
 * checksum field of an IPv4 frame and the GEM fills it.  Older firmware
 * reads the register as 0: no capabilities, no verdict.
 */
#define ETH_RX_META_PRESENT 0x8000u
#define ETH_TX_CSUM_PRESENT 0x4000u
#define ETH_RX_META_MASK    0x0003u
#define ETH_RX_META_NONE    0u
#define ETH_RX_META_IP      1u
#define ETH_RX_META_TCP     2u
#define ETH_RX_META_UDP     3u
u16 ethernet_get_rx_meta(void);

#endif
