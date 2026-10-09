/* SPDX-License-Identifier: MIT
 * Actual init/prepare/clear and BSP ring bodies. Hardware and fence/rearm are
 * explicit contract stubs; fault injection reaches the real BSP error paths.
 */
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "../../experimental/zz_eth_rx_lease.h"
typedef uint32_t u32;
typedef uint16_t u16;
typedef uint8_t u8;
typedef uintptr_t UINTPTR;
typedef long LONG;
typedef u32 XEmacPs_Bd[2];
#define XST_SUCCESS 0
#define XST_FAILURE 1
#define XST_INVALID_PARAM 2
#define XST_DMA_SG_LIST_ERROR 3
#define XST_DMA_SG_NO_LIST 4
#define XST_DEVICE_IS_STARTED 5
#define XST_DMA_SG_IS_STOPPED 6
#define XST_DMA_SG_IS_STARTED 7
#define Xil_AssertNonvoid(x) assert(x)
#define FRAME_MAX_BACKLOG 128
#define FRAME_SIZE 2048
#define RX_FRAME_PAD 4
#define ETH_INVALID_BACKLOG_SLOT 0xffffu
#define ETH_BACKLOG_HIGH_WATERMARK 120
#define MNTZ_BASE_ADDR 0u
#define MNTZORRO_REG4 4u
/* BSP_DEFINITIONS */
typedef struct { XEmacPs_BdRing RxRing, TxRing; } XEmacPs;
static XEmacPs EmacPsInstance;
static XEmacPs_Bd rx[RXBD_CNT], tx[TXBD_CNT];
#define RX_BD_LIST_START_ADDRESS ((UINTPTR)rx)
#define TX_BD_LIST_START_ADDRESS ((UINTPTR)tx)
#define XEmacPs_GetRxRing(p) ((p)->RxRing)
#define XEmacPs_GetTxRing(p) ((p)->TxRing)
#define XEMACPS_BD_TO_INDEX(r, bd) ((u32)(((UINTPTR)(bd) - (r)->BaseBdAddr) / (r)->Separation))
static struct zz_rx_lease packet_leases;
static int packet_mode, packet_fault, packet_can_clear, packet_session_started;
static int frames_dropped, frames_backlog_full, rx_backpressure, rx_pause_frames, rx_slot_mismatch;
static u16 frames_backlog, frames_backlog_read, frames_backlog_write;
static u16 frames_backlog_reserved, frames_backlog_reserve, frame_serial;
static u16 rx_bd_backlog_slot[RXBD_CNT];
static u32 frames_received, FramesRx, FramesTx;
static int eth_tx_ord;
static unsigned stopped, running, fences, clears, creates, clones, allocs;
static unsigned prepared, commits, barriers, grants, rearms, starts;
static int fence_ok, rearm_ok;
static const char *failure;
static unsigned prepare_failure;

static void bd_write(XEmacPs_Bd *bd, unsigned offset, UINTPTR value)
{
    UINTPTR p = (UINTPTR)bd;
    if (p >= (UINTPTR)rx && p < (UINTPTR)(rx + RXBD_CNT) && offset == XEMACPS_BD_ADDR_OFFSET &&
        !(value & XEMACPS_RXBUF_NEW_MASK)) {
        unsigned i = XEMACPS_BD_TO_INDEX(&EmacPsInstance.RxRing, bd);
        unsigned slot = rx_bd_backlog_slot[i];
        assert(!running && commits == 1 && barriers == 1);
        assert(EmacPsInstance.RxRing.HwCnt == RXBD_CNT && frames_backlog_reserved == RXBD_CNT);
        assert(slot == i && (value & XEMACPS_RXBUF_ADD_MASK) == 0x100000u + slot * FRAME_SIZE + RX_FRAME_PAD);
        grants++;
    }
    *(u32 *)((u8 *)bd + offset) = (u32)value;
}
#define XEmacPs_BdRead(bd, offset) (*(u32 *)((u8 *)(bd) + (offset)))
#define XEmacPs_BdWrite(bd, offset, value) bd_write((bd), (offset), (value))
/* BSP_FUNCTIONS */
static int failing(const char *stage) { return failure && !strcmp(failure, stage); }
static void XEmacPs_Stop(XEmacPs *p) { assert(p == &EmacPsInstance); running = 0; stopped++; }
static int ethernet_packet_fence(void)
{
    assert(stopped && !running); fences++;
    packet_can_clear = fence_ok;
    return fence_ok;
}
static void eth_tx_order_flush(int *p)
{ assert(p == &eth_tx_ord && fences && fence_ok && !running); clears++; }
static void ethernet_clear_backlog_slot(u16 slot)
{ assert(slot < FRAME_MAX_BACKLOG && !running && fences && fence_ok); }
static void mntzorro_write(unsigned base, unsigned reg, unsigned value)
{ assert(base == MNTZ_BASE_ADDR && reg == MNTZORRO_REG4 && !value); }
static u16 ethernet_backlog_pending(void) { return frames_backlog + frames_backlog_reserved; }
static u16 ethernet_next_backlog_slot(u16 slot) { return (slot + 1u) % FRAME_MAX_BACKLOG; }
static void ethernet_send_pause_frame(void) { rx_pause_frames++; }
static u8 *ethernet_backlog_payload_ptr(u16 slot)
{ return (u8 *)(UINTPTR)(0x100000u + slot * FRAME_SIZE + RX_FRAME_PAD); }
/* FIRMWARE_HELPERS */

static LONG checked_create(XEmacPs_BdRing *r, UINTPTR phys, UINTPTR virt, u32 align, u32 count)
{
    assert(fences && fence_ok && clears && !running); creates++;
    const char *stage = r == &EmacPsInstance.RxRing ? "rx-create" : "tx-create";
    /* Misalignment exercises the real Create rejection before touching storage. */
    return XEmacPs_BdRingCreate(r, phys, virt, failing(stage) ? 0 : align, count);
}
static LONG checked_clone(XEmacPs_BdRing *r, XEmacPs_Bd *pattern, u8 direction)
{
    assert(!running); clones++;
    if (failing(direction == XEMACPS_RECV ? "rx-clone" : "tx-clone")) r->RunState = XST_DMA_SG_IS_STARTED;
    LONG status = XEmacPs_BdRingClone(r, pattern, direction);
    if (status == XST_SUCCESS) {
        for (u32 i = 0; i < r->AllCnt; i++) {
            XEmacPs_Bd *bd = (XEmacPs_Bd *)(r->BaseBdAddr + i * r->Separation);
            if (direction == XEMACPS_RECV) {
                assert((*bd)[0] & XEMACPS_RXBUF_NEW_MASK);
                assert(!!((*bd)[0] & XEMACPS_RXBUF_WRAP_MASK) == (i + 1 == r->AllCnt));
            } else {
                assert((*bd)[1] & XEMACPS_TXBUF_USED_MASK);
                assert(!!((*bd)[1] & XEMACPS_TXBUF_WRAP_MASK) == (i + 1 == r->AllCnt));
            }
        }
    }
    return status;
}
static LONG checked_alloc(XEmacPs_BdRing *r, u32 count, XEmacPs_Bd **set)
{ allocs++; return XEmacPs_BdRingAlloc(r, failing("alloc") ? count + 1 : count, set); }
static int checked_prepare(XEmacPs_BdRing *r, XEmacPs_Bd *bd)
{
    if (failing("prepare") && prepared == prepare_failure) frames_backlog = ETH_BACKLOG_HIGH_WATERMARK;
    prepared++;
    return ethernet_prepare_rx_bd(r, bd);
}
static LONG checked_commit(XEmacPs_BdRing *r, u32 count, XEmacPs_Bd *set)
{
    assert(!running && !grants && !barriers && frames_backlog_reserved == RXBD_CNT);
    if (failing("commit")) r->PreHead = XEmacPs_BdRingNext(r, set);
    LONG status = XEmacPs_BdRingToHw(r, count, set);
    if (status == XST_SUCCESS) commits++;
    return status;
}
static void barrier(void) { assert(commits == 1 && !grants && !running); barriers++; }
static int ethernet_packet_rearm(void)
{
    assert(commits == 1 && barriers == 1 && grants == RXBD_CNT && !running); rearms++;
    if (rearm_ok) { packet_session_started = 1; packet_can_clear = 0; }
    return rearm_ok;
}
static void XEmacPs_Start(XEmacPs *p)
{
    assert(p == &EmacPsInstance && rearms == 1 && rearm_ok && !running);
    assert(commits == 1 && barriers == 1 && grants == RXBD_CNT);
    starts++; running = 1;
}
#define XEmacPs_BdRingCreate checked_create
#define XEmacPs_BdRingClone checked_clone
#define XEmacPs_BdRingAlloc checked_alloc
#define ethernet_prepare_rx_bd checked_prepare
#define XEmacPs_BdRingToHw checked_commit
#define dsb() barrier()
/* INIT_FUNCTION */

static void reset_observers(void)
{
    stopped = fences = clears = creates = clones = allocs = prepared = 0;
    commits = barriers = grants = rearms = starts = 0;
}
static void setup(void)
{
    memset(&EmacPsInstance, 0, sizeof(EmacPsInstance));
    memset(rx, 0xa5, sizeof(rx)); memset(tx, 0x5a, sizeof(tx));
    memset(rx_bd_backlog_slot, 0xff, sizeof(rx_bd_backlog_slot));
    zz_rx_lease_init(&packet_leases);
    frames_backlog = 7; frames_backlog_reserved = 3; frames_backlog_reserve = 17;
    packet_session_started = 1; packet_can_clear = 0; packet_fault = 0;
    running = 1; fence_ok = rearm_ok = 1; failure = NULL; prepare_failure = 7;
    reset_observers();
}
static void check_success(void)
{
    assert(init_ethernet_buffers() == XST_SUCCESS);
    assert(stopped == 1 && fences == 1 && clears == 1 && creates == 2 && clones == 2);
    assert(allocs == 1 && prepared == RXBD_CNT && commits == 1 && barriers == 1);
    assert(grants == RXBD_CNT && rearms == 1 && starts == 1 && running);
    assert(!packet_fault && !frames_backlog && frames_backlog_reserved == RXBD_CNT);
    assert(EmacPsInstance.RxRing.HwCnt == RXBD_CNT && !EmacPsInstance.RxRing.FreeCnt);
    assert(!EmacPsInstance.RxRing.PreCnt && !EmacPsInstance.RxRing.PostCnt);
    for (unsigned i = 0; i < RXBD_CNT; i++) assert(!(rx[i][0] & XEMACPS_RXBUF_NEW_MASK));
}
static void check_fence_preserves(void)
{
    XEmacPs before = EmacPsInstance;
    XEmacPs_Bd old_rx[RXBD_CNT], old_tx[TXBD_CNT];
    u16 old_slots[RXBD_CNT];
    memcpy(old_rx, rx, sizeof(rx)); memcpy(old_tx, tx, sizeof(tx));
    memcpy(old_slots, rx_bd_backlog_slot, sizeof(old_slots));
    u16 old_backlog = frames_backlog, old_reserved = frames_backlog_reserved;
    fence_ok = 0; reset_observers();
    assert(init_ethernet_buffers() == XST_FAILURE);
    assert(stopped == 1 && fences == 1 && !clears && !creates && !grants && !starts && !running);
    assert(!memcmp(&before, &EmacPsInstance, sizeof(before)));
    assert(!memcmp(old_rx, rx, sizeof(rx)) && !memcmp(old_tx, tx, sizeof(tx)));
    assert(!memcmp(old_slots, rx_bd_backlog_slot, sizeof(old_slots)));
    assert(frames_backlog == old_backlog && frames_backlog_reserved == old_reserved);
}
int main(int argc, char **argv)
{
    assert(argc == 3 && (!strcmp(argv[2], "packet") || !strcmp(argv[2], "legacy")));
    packet_mode = strcmp(argv[2], "legacy") != 0;
    setup();
    if (!strcmp(argv[1], "success")) {
        /* Both a cold session and a stopped/reinitialized prior session. */
        packet_session_started = 0; check_success();
        reset_observers(); check_success();
    } else if (!strcmp(argv[1], "fence")) {
        check_fence_preserves();
    } else if (!strcmp(argv[1], "rearm")) {
        rearm_ok = 0;
        assert(init_ethernet_buffers() == XST_FAILURE);
        assert(grants == RXBD_CNT && frames_backlog_reserved == RXBD_CNT && !running && !starts);
        check_fence_preserves(); /* Retry must not clear the failed-rearm ring without a new fence. */
        fence_ok = rearm_ok = 1; reset_observers(); check_success();
    } else {
        unsigned runs = !strcmp(argv[1], "prepare") ? 3 : 1;
        const unsigned positions[] = {0, 7, 63};
        for (unsigned run = 0; run < runs; run++) {
            setup(); failure = argv[1]; prepare_failure = positions[run];
            assert(init_ethernet_buffers() == XST_FAILURE);
            assert(!running && !starts && !rearms && !grants && !commits && !barriers);
            assert(!frames_backlog_reserved && !frames_backlog);
            if (failing("prepare") || failing("commit")) {
                assert(clears == 2 && EmacPsInstance.RxRing.FreeCnt == RXBD_CNT && !EmacPsInstance.RxRing.PreCnt);
                for (unsigned i = 0; i < RXBD_CNT; i++) {
                    assert(rx_bd_backlog_slot[i] == ETH_INVALID_BACKLOG_SLOT);
                    assert(rx[i][0] & XEMACPS_RXBUF_NEW_MASK);
                }
            }
            failure = NULL; reset_observers(); check_success();
        }
    }
    printf("PASS init %s (%s)\n", argv[1], argv[2]);
    return 0;
}
