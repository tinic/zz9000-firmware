/* SPDX-License-Identifier: MIT
 * Host fixture for exact firmware RX and BSP ring code. DMA advances explicitly;
 * address writes are observed to catch ownership publication before reservation.
 */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef uint32_t u32;
typedef uint16_t u16;
typedef uint8_t u8;
typedef uintptr_t UINTPTR;
typedef long LONG;
typedef u32 XEmacPs_Bd[2];
#define TRUE 1
#define FALSE 0
#define XST_SUCCESS 0
#define XST_FAILURE 1
#define XST_DMA_SG_LIST_ERROR 2
#define Xil_AssertNonvoid(x) assert(x)
#define RXBD_CNT 64
#define FRAME_MAX_BACKLOG 128
#define FRAME_SIZE 2048
#define RX_FRAME_PAD 4
#define ETH_INVALID_BACKLOG_SLOT 0xffffu
#define ETH_BACKLOG_HIGH_WATERMARK 120
#define XEMACPS_RXSR_OFFSET 0u
static unsigned barriers;
#define dsb() ((void)++barriers)
/* BSP_DEFINITIONS */
typedef struct { struct { u32 BaseAddress; } Config; XEmacPs_BdRing RxRing; } XEmacPs;
static XEmacPs EmacPsInstance;
static XEmacPs_Bd descriptors[RXBD_CNT];
static int rx_backpressure, frames_dropped;
static int frames_backlog_full, rx_slot_mismatch;
static u16 frames_backlog, frames_backlog_read, frames_backlog_write;
static u16 frames_backlog_reserved, frames_backlog_reserve, frame_serial;
static u16 rx_bd_backlog_slot[RXBD_CNT];
static u8 rx_backlog_csum[FRAME_MAX_BACKLOG];
static u32 frames_received;
static unsigned grants, unsafe_grants, pauses, clears, watch_grants;
static u8 frame_bytes[FRAME_MAX_BACKLOG][FRAME_SIZE];
#define XEmacPs_GetRxRing(instance) ((instance)->RxRing)
/* Pointer-sized host indexing replaces only the target's 32-bit address cast. */
#define XEMACPS_BD_TO_INDEX(ring, bd) ((u32)(((UINTPTR)(bd) - (ring)->BaseBdAddr) / (ring)->Separation))
#define XEmacPs_BdRead(bd, offset) (*(u32 *)((u8 *)(bd) + (offset)))
static void bd_write(XEmacPs_Bd *bd, unsigned offset, UINTPTR value)
{
    u32 *word = (u32 *)((u8 *)bd + offset);
    *word = (u32)value;
    if (watch_grants && offset == XEMACPS_BD_ADDR_OFFSET && !(value & XEMACPS_RXBUF_NEW_MASK)) {
        unsigned i = XEMACPS_BD_TO_INDEX(&EmacPsInstance.RxRing, bd);
        unsigned slot = rx_bd_backlog_slot[i];
        grants++;
        if (slot >= FRAME_MAX_BACKLOG ||
            (value & XEMACPS_RXBUF_ADD_MASK) != 0x100000u + slot * FRAME_SIZE + RX_FRAME_PAD ||
            !EmacPsInstance.RxRing.HwCnt || !frames_backlog_reserved || barriers != grants)
            unsafe_grants++;
    }
}
#define XEmacPs_BdWrite(bd, offset, value) bd_write((bd), (offset), (value))
/* BSP_FUNCTIONS */
static u16 ethernet_next_backlog_slot(u16 slot) { return (slot + 1u) % FRAME_MAX_BACKLOG; }
static u16 ethernet_previous_backlog_slot(u16 slot) { return (slot + FRAME_MAX_BACKLOG - 1u) % FRAME_MAX_BACKLOG; }
static u16 ethernet_backlog_pending(void) { return frames_backlog + frames_backlog_reserved; }
static void ethernet_send_pause_frame(void) { pauses++; }
static void ethernet_clear_backlog_slot(u16 slot) { assert(slot < FRAME_MAX_BACKLOG); clears++; }
static u8 *ethernet_backlog_payload_ptr(u16 slot) { return (u8 *)(UINTPTR)(0x100000u + slot * FRAME_SIZE + RX_FRAME_PAD); }
static u8 *ethernet_backlog_slot_ptr(u16 slot) { assert(slot < FRAME_MAX_BACKLOG); return frame_bytes[slot]; }
static void ethernet_backlog_slot_publish_from(u16 slot, u32 from, u32 bytes)
{ assert(slot < FRAME_MAX_BACKLOG && from + bytes <= FRAME_SIZE); }
static u32 XEmacPs_ReadReg(u32 base, u32 offset) { (void)base; (void)offset; return 0; }
static void XEmacPs_WriteReg(u32 base, u32 offset, u32 value) { (void)base; (void)offset; (void)value; }
/* RX_FUNCTIONS */
static void setup(void)
{
    memset(&EmacPsInstance, 0, sizeof(EmacPsInstance)); memset(descriptors, 0, sizeof(descriptors));
    XEmacPs_BdRing *r = &EmacPsInstance.RxRing;
    r->BaseBdAddr = r->PhysBaseAddr = (UINTPTR)&descriptors[0];
    r->HighBdAddr = (UINTPTR)&descriptors[RXBD_CNT - 1];
    r->Separation = sizeof(descriptors[0]); r->Length = sizeof(descriptors);
    r->FreeHead = r->PreHead = r->HwHead = r->HwTail = r->PostHead = &descriptors[0];
    r->AllCnt = r->FreeCnt = RXBD_CNT;
    for (unsigned i = 0; i < RXBD_CNT; i++) {
        descriptors[i][0] = XEMACPS_RXBUF_NEW_MASK | (i == RXBD_CNT - 1 ? XEMACPS_RXBUF_WRAP_MASK : 0);
        rx_bd_backlog_slot[i] = ETH_INVALID_BACKLOG_SLOT;
    }
    rx_backpressure = frames_dropped = frames_backlog_full = rx_slot_mismatch = 0;
    frames_backlog = frames_backlog_read = frames_backlog_write = frames_backlog_reserved = frames_backlog_reserve = frame_serial = 0;
    frames_received = barriers = grants = unsafe_grants = pauses = clears = watch_grants = 0;
}
static void complete(unsigned bd)
{
    assert(!(descriptors[bd][0] & XEMACPS_RXBUF_NEW_MASK));
    descriptors[bd][1] = XEMACPS_RXBUF_EOF_MASK | 1514u;
    descriptors[bd][0] |= XEMACPS_RXBUF_NEW_MASK;
}
static void arm_last_slot(void)
{
    frames_backlog = frames_backlog_write = frames_backlog_reserve = 119;
    ethernet_alloc_rx_frames();
    assert(frames_backlog_reserved == 1 && EmacPsInstance.RxRing.HwCnt == 1);
}
int main(int argc, char **argv)
{
    assert(argc == 2); setup();
    XEmacPs_BdRing *r = &EmacPsInstance.RxRing;
    if (!strcmp(argv[1], "pressure")) {
        arm_last_slot(); complete(0); XEmacPsRecvHandler(&EmacPsInstance);
        assert(frames_backlog == 120 && !frames_backlog_reserved && !r->HwCnt && r->FreeCnt == 64);
        assert(descriptors[0][0] & XEMACPS_RXBUF_NEW_MASK);
        puts("PASS pressure: completed descriptor stays CPU-owned while refill is withheld");
    } else if (!strcmp(argv[1], "scan")) {
        arm_last_slot(); complete(0);
        /* Software-owned descriptors may retain old EOF/NEW from prior laps. */
        for (unsigned i = 1; i < RXBD_CNT; i++) descriptors[i][1] = XEMACPS_RXBUF_EOF_MASK | 1514u;
        XEmacPsRecvHandler(&EmacPsInstance);
        assert(frames_received == 1 && !r->HwCnt && r->FreeCnt == 64 && !frames_dropped);
        puts("PASS scan: completion count is bounded by actual hardware-owned work group");
    } else if (!strcmp(argv[1], "publish")) {
        descriptors[0][0] |= 0x100000u + 17u * FRAME_SIZE + RX_FRAME_PAD;
        watch_grants = 1; arm_last_slot();
        assert(grants == 1 && !unsafe_grants);
        assert(rx_bd_backlog_slot[0] == 119 && !(descriptors[0][0] & XEMACPS_RXBUF_NEW_MASK));
        puts("PASS publish: new address, reservation and ring accounting precede NEW handoff");
    } else if (!strcmp(argv[1], "rollback")) {
        frames_backlog = frames_backlog_write = frames_backlog_reserve = 119;
        r->PreHead = &descriptors[1]; /* Inject BSP out-of-sequence ToHw rejection. */
        barriers = 0; watch_grants = 1; ethernet_alloc_rx_frames();
        assert(!grants && !r->HwCnt && r->FreeCnt == 64 && !r->PreCnt && !frames_backlog_reserved);
        assert(rx_bd_backlog_slot[0] == ETH_INVALID_BACKLOG_SLOT && frames_backlog_reserve == 119);
        assert(descriptors[0][0] & XEMACPS_RXBUF_NEW_MASK);
        puts("PASS rollback: failed ToHw never grants DMA ownership");
    } else if (!strcmp(argv[1], "burst")) {
        ethernet_alloc_rx_frames();
        for (unsigned i = 0; i < 64; i++) complete(i);
        XEmacPsRecvHandler(&EmacPsInstance);
        assert(frames_backlog == 64 && frames_backlog_reserved == 56 && r->HwCnt == 56);
        for (unsigned i = 0; i < 56; i++) complete(i);
        XEmacPsRecvHandler(&EmacPsInstance);
        assert(frames_received == 120 && !frames_dropped);
        assert(frames_backlog == 120 && !r->HwCnt && r->FreeCnt == 64 && !frames_backlog_reserved);
        assert(r->FreeHead == &descriptors[56] && (descriptors[56][0] & XEMACPS_RXBUF_NEW_MASK));
        puts("PASS burst: 64 then 56 completions stop exactly at watermark without stale-BD overcount");
    } else {
        assert(!strcmp(argv[1], "cycle"));
        ethernet_alloc_rx_frames();
        unsigned hw = 0;
        for (unsigned n = 0; n < 120; n++) {
            complete(hw); hw = (hw + 1) % RXBD_CNT;
            XEmacPsRecvHandler(&EmacPsInstance);
            assert(r->HwCnt + r->FreeCnt + r->PreCnt + r->PostCnt == RXBD_CNT);
        }
        assert(frames_backlog == 120 && frames_received == 120 && !frames_backlog_reserved);
        assert(hw == 56 && !r->HwCnt && r->FreeCnt == 64 && r->FreeHead == &descriptors[56]);
        assert(descriptors[hw][0] & XEMACPS_RXBUF_NEW_MASK);
        /* Model the host releasing the 120 completed slots, then refill. */
        frames_backlog = 0; frames_backlog_read = frames_backlog_write;
        barriers = 0; watch_grants = 1; ethernet_alloc_rx_frames();
        assert(!unsafe_grants && r->HwCnt == 64 && frames_backlog_reserved == 64);
        for (unsigned n = 0; n < 32; n++) {
            complete(hw); hw = (hw + 1) % RXBD_CNT;
            XEmacPsRecvHandler(&EmacPsInstance);
            assert(!frames_dropped);
        }
        puts("PASS cycle: 120-packet pressure stop at BD56, host drain, refill and receive resume");
    }
    return 0;
}
