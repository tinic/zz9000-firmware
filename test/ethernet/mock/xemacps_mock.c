/* Host-side BD ring model. See xemacps.h for the contract. */
#include <string.h>
#include <stdint.h>
#include "xemacps.h"
#include "memorymap.h"
#include "mntzorro.h"
#include "interrupt.h"

#define MOCK_IDX(r, bd) ((u32)((XEmacPs_Bd *)(bd) - (r)->base))

int mock_bdfree_fail_remaining = 0;
int mock_bdfree_calls = 0;
int mock_bdfree_failed_calls = 0;
static int mock_double_release = 0;
static XEmacPs_BdRing *g_rx = 0;
u32 mock_reg4_last = 0;

void mntzorro_write(u32 base, u32 reg, u32 val) { (void)base; if (reg == MNTZORRO_REG4) mock_reg4_last = val; }
u32  mntzorro_read(u32 base, u32 reg) { (void)base; (void)reg; return 0; }

void mock_ring_reset(void) {
    mock_bdfree_fail_remaining = 0;
    mock_bdfree_calls = 0;
    mock_bdfree_failed_calls = 0;
    mock_double_release = 0;
}
u32 mock_rx_free_count(void) { return g_rx ? g_rx->FreeCnt : 0; }
u32 mock_rx_stranded_count(void) { return g_rx ? g_rx->PostCnt : 0; }
u32 mock_rx_capacity(void) { return g_rx ? (g_rx->cnt - g_rx->PostCnt) : 0; }
u32 mock_rx_inflight(void) { return g_rx ? g_rx->HwCnt : 0; }
int mock_rx_double_release(void) { return mock_double_release; }

void XEmacPs_BdClear(XEmacPs_Bd *bd) { memset(bd, 0, sizeof(*bd)); }
void XEmacPs_BdClearRxNew(XEmacPs_Bd *bd) { bd->w[0] &= ~1u; }
void XEmacPs_BdClearTxUsed(XEmacPs_Bd *bd) { bd->w[1] &= ~XEMACPS_TXBUF_USED_MASK; }
u32  XEmacPs_BdGetLength(XEmacPs_Bd *bd) { return bd->w[1] & XEMACPS_TXBUF_LEN_MASK; }
u32  XEmacPs_BdGetStatus(XEmacPs_Bd *bd) { return bd->w[1]; }
void XEmacPs_BdSetAddressRx(XEmacPs_Bd *bd, void *a) { bd->w[0] = (u32)(uintptr_t)a; }
void XEmacPs_BdSetAddressTx(XEmacPs_Bd *bd, void *a) { bd->w[0] = (u32)(uintptr_t)a; }
void XEmacPs_BdSetLast(XEmacPs_Bd *bd) { bd->w[1] |= XEMACPS_TXBUF_LAST_MASK; }
void XEmacPs_BdSetLength(XEmacPs_Bd *bd, u32 l) { bd->w[1] = (bd->w[1] & ~XEMACPS_TXBUF_LEN_MASK) | (l & XEMACPS_TXBUF_LEN_MASK); }
void XEmacPs_BdSetStatus(XEmacPs_Bd *bd, u32 s) { bd->w[1] |= s; }

LONG XEmacPs_BdRingCreate(XEmacPs_BdRing *r, UINTPTR phys, UINTPTR virt, u32 align, u32 cnt) {
    (void)phys; (void)align;
    if (cnt > MOCK_RING_MAX) return XST_FAILURE;
    r->base = (XEmacPs_Bd *)(uintptr_t)virt;
    r->BaseBdAddr = (UINTPTR)virt;
    r->Separation = (u32)sizeof(XEmacPs_Bd);
    r->cnt = cnt;
    memset(r->state, 0, sizeof(r->state));
    r->FreeCnt = cnt; r->PreCnt = r->HwCnt = r->PostCnt = 0; r->AllCnt = cnt;
    r->next_free = 0;
    if (!g_rx) g_rx = r;          /* first ring created is RX (ethernet.c order) */
    return XST_SUCCESS;
}
LONG XEmacPs_BdRingClone(XEmacPs_BdRing *r, XEmacPs_Bd *t, u8 d) { (void)r;(void)t;(void)d; return XST_SUCCESS; }

LONG XEmacPs_BdRingAlloc(XEmacPs_BdRing *r, u32 n, XEmacPs_Bd **bd) {
    /* The real API hands back n CONTIGUOUS BDs, and ethernet.c relies on
     * that when it allocates the whole ring at init and then walks it. */
    if (r->FreeCnt < n || n == 0) return XST_FAILURE;
    for (u32 start = 0; start + n <= r->cnt; start++) {
        u32 k;
        for (k = 0; k < n; k++)
            if (r->state[start + k] != 0) break;
        if (k != n) continue;
        for (k = 0; k < n; k++) {
            r->state[start + k] = 1;
            r->FreeCnt--; r->PreCnt++;
        }
        r->next_free = (start + n) % r->cnt;
        *bd = &r->base[start];
        return XST_SUCCESS;
    }
    return XST_FAILURE;
}
LONG XEmacPs_BdRingToHw(XEmacPs_BdRing *r, u32 n, XEmacPs_Bd *bd) {
    for (u32 k = 0; k < n; k++) {
        u32 idx = MOCK_IDX(r, bd) + k;
        if (idx >= r->cnt || r->state[idx] != 1) return XST_FAILURE;
        r->state[idx] = 2; r->PreCnt--; r->HwCnt++;
    }
    return XST_SUCCESS;
}
u32 XEmacPs_BdRingFromHwRx(XEmacPs_BdRing *r, u32 n, XEmacPs_Bd **bd) {
    u32 got = 0;
    for (u32 idx = 0; idx < r->cnt && got < n; idx++) {
        if (r->state[idx] == 2) {
            if (got == 0) *bd = &r->base[idx];
            r->state[idx] = 3; r->HwCnt--; r->PostCnt++; got++;
        }
    }
    return got;
}
u32 XEmacPs_BdRingFromHwTx(XEmacPs_BdRing *r, u32 n, XEmacPs_Bd **bd) { return XEmacPs_BdRingFromHwRx(r, n, bd); }

LONG XEmacPs_BdRingFree(XEmacPs_BdRing *r, u32 n, XEmacPs_Bd *bd) {
    mock_bdfree_calls++;
    if (mock_bdfree_fail_remaining > 0) {
        mock_bdfree_fail_remaining--;
        mock_bdfree_failed_calls++;
        return XST_FAILURE;        /* BDs stay in 'post': stranded */
    }
    for (u32 k = 0; k < n; k++) {
        u32 idx = MOCK_IDX(r, bd) + k;
        if (idx >= r->cnt) return XST_FAILURE;
        if (r->state[idx] == 0) { mock_double_release = 1; return XST_FAILURE; }
        if (r->state[idx] == 3) { r->PostCnt--; }
        r->state[idx] = 0; r->FreeCnt++;
    }
    return XST_SUCCESS;
}
LONG XEmacPs_BdRingUnAlloc(XEmacPs_BdRing *r, u32 n, XEmacPs_Bd *bd) {
    for (u32 k = 0; k < n; k++) {
        u32 idx = MOCK_IDX(r, bd) + k;
        if (idx >= r->cnt || r->state[idx] != 1) return XST_FAILURE;
        r->state[idx] = 0; r->PreCnt--; r->FreeCnt++;
    }
    return XST_SUCCESS;
}
u32 XEmacPs_BdRingGetFreeCnt(XEmacPs_BdRing *r) { return r->FreeCnt; }
XEmacPs_Bd *XEmacPs_BdRingNext(XEmacPs_BdRing *r, XEmacPs_Bd *bd) {
    u32 idx = MOCK_IDX(r, bd);
    return &r->base[(idx + 1) % r->cnt];
}
u32 XEmacPs_BdRingMemCalc(u32 a, u32 c) { (void)a; return c * sizeof(XEmacPs_Bd); }

static XEmacPs_Config g_cfg;
XEmacPs_Config *XEmacPs_LookupConfig(u16 id) { (void)id; g_cfg.BaseAddress = 0; return &g_cfg; }
LONG XEmacPs_CfgInitialize(XEmacPs *p, XEmacPs_Config *c, u32 b) { (void)c; p->Config.BaseAddress = b; return XST_SUCCESS; }
void XEmacPs_Start(XEmacPs *p) { p->started = 1; }
void XEmacPs_Stop(XEmacPs *p) { p->started = 0; }
void XEmacPs_IntEnable(XEmacPs *p, u32 m) { (void)p;(void)m; }
void XEmacPs_IntDisable(XEmacPs *p, u32 m) { (void)p;(void)m; }
u32  XEmacPs_ReadReg(u32 b, u32 o) { (void)b;(void)o; return 0; }
void XEmacPs_WriteReg(u32 b, u32 o, u32 v) { (void)b;(void)o;(void)v; }
LONG XEmacPs_SetHandler(XEmacPs *p, u32 k, void *f, void *r) { (void)p;(void)k;(void)f;(void)r; return XST_SUCCESS; }
LONG XEmacPs_SetMacAddress(XEmacPs *p, void *m, u8 i) { (void)p;(void)m;(void)i; return XST_SUCCESS; }
void XEmacPs_SetMdioDivisor(XEmacPs *p, u32 d) { (void)p;(void)d; }
void XEmacPs_SetOperatingSpeed(XEmacPs *p, u16 s) { (void)p;(void)s; }
LONG XEmacPs_PhyRead(XEmacPs *p, u32 a, u32 r, u16 *v) { (void)p;(void)a;(void)r; if (v) *v = 0; return XST_SUCCESS; }
LONG XEmacPs_PhyWrite(XEmacPs *p, u32 a, u32 r, u16 v) { (void)p;(void)a;(void)r;(void)v; return XST_SUCCESS; }
LONG XEmacPs_Transmit(XEmacPs *p) { (void)p; return XST_SUCCESS; }
LONG XEmacPs_SendPausePacket(XEmacPs *p) { (void)p; return XST_SUCCESS; }
void XEmacPs_IntrHandler(void *p) { (void)p; }

/* Host storage standing in for the card's fixed addresses (memorymap.h). */
uint8_t mock_tx_bd_list[64 * 8];
uint8_t mock_rx_bd_list[64 * 8];
uint8_t mock_tx_frame[16 * 1024];
uint8_t mock_rx_frame[16 * 1024];
uint8_t mock_rx_backlog[128 * 2048];
uint8_t mock_ieee_page[4096];
uint8_t mock_usb_block[4096];

static XScuGic g_intc;
XScuGic *interrupt_get_intc(void) { return &g_intc; }
