#ifndef MOCK_MEMORYMAP_H
#define MOCK_MEMORYMAP_H
/*
 * Host-backed stand-ins for the card's fixed addresses. The firmware treats
 * these as raw addresses, so the model has to hand it real storage of the
 * same geometry or every BD/slot dereference is a wild pointer.
 * Backlog: FRAME_MAX_BACKLOG(128) * 2048 = 256 KiB, matching the comment on
 * RX_BACKLOG_ADDRESS in the real memorymap.h.
 */
#include <stdint.h>
extern uint8_t mock_tx_bd_list[64 * 8];
extern uint8_t mock_rx_bd_list[64 * 8];
extern uint8_t mock_tx_frame[16 * 1024];
extern uint8_t mock_rx_frame[16 * 1024];
extern uint8_t mock_rx_backlog[128 * 2048];
extern uint8_t mock_ieee_page[4096];

#define TX_BD_LIST_START_ADDRESS ((uintptr_t)mock_tx_bd_list)
#define RX_BD_LIST_START_ADDRESS ((uintptr_t)mock_rx_bd_list)
#define TX_FRAME_ADDRESS         ((uintptr_t)mock_tx_frame)
#define RX_FRAME_ADDRESS         ((uintptr_t)mock_rx_frame)
#define RX_BACKLOG_ADDRESS       ((uintptr_t)mock_rx_backlog)
#define IEEE_PAGE_ADDRESS        ((uintptr_t)mock_ieee_page)
#define RX_FRAME_PAD 4
#define FRAME_SIZE   2048
#define USB_BLOCK_STORAGE_ADDRESS ((uintptr_t)mock_usb_block)
extern uint8_t mock_usb_block[4096];
#endif
