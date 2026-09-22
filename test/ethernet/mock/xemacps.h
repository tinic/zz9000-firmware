#ifndef MOCK_XEMACPS_H
#define MOCK_XEMACPS_H
/*
 * Host-side model of the XEmacPs BD ring, enough to exercise ethernet.c's
 * RX bookkeeping. The point of the model is CAPACITY: a BD lives in exactly
 * one of free / pre / hw / post, and XEmacPs_BdRingFree is the only way back
 * to free. Failing that call therefore strands BDs, which is the defect
 * under test.
 */
#include "platform.h"

#define XEMACPS_BD_NUM_WORDS 2
typedef struct { u32 w[XEMACPS_BD_NUM_WORDS]; } XEmacPs_Bd;

#define MOCK_RING_MAX 64
typedef struct {
    XEmacPs_Bd *base;
    UINTPTR BaseBdAddr;
    u32 Separation;
    u32 cnt;
    /* state per BD index: 0 free, 1 pre, 2 hw, 3 post */
    u8  state[MOCK_RING_MAX];
    u32 FreeCnt, PreCnt, HwCnt, PostCnt, AllCnt;
    u32 PostHead;   /* first BD of the post set, as the real ring keeps */
    u32 next_free;
} XEmacPs_BdRing;

typedef struct { u32 BaseAddress; u16 DeviceId; } XEmacPs_Config;
typedef struct {
    XEmacPs_Config Config;
    XEmacPs_BdRing rx, tx;
    int started;
} XEmacPs;

#define XEMACPS_BD_ALIGNMENT 4
#define XEMACPS_SEND 1
#define XEMACPS_RECV 2
#define XEMACPS_HANDLER_DMASEND 1
#define XEMACPS_HANDLER_DMARECV 2
#define XEMACPS_HANDLER_ERROR   3
#define XEMACPS_MAX_VLAN_FRAME_SIZE_JUMBO 9000
#define XEMACPS_0_DEVICE_ID 0
#define MDC_DIV_224 7

/* register offsets / masks: values are irrelevant to the model */
#define XEMACPS_NWCTRL_OFFSET 0x00
#define XEMACPS_TXPAUSE_OFFSET 0x04
#define XEMACPS_ISR_OFFSET 0x08
#define XEMACPS_IMR_OFFSET 0x0c
#define XEMACPS_RXSR_OFFSET 0x10
#define XEMACPS_TXSR 0x14
#define XEMACPS_TXSR_OFFSET 0x14
#define XEMACPS_IXR_FRAMERX_MASK 0x02
#define XEMACPS_IXR_RX_ERR_MASK  0x04
#define XEMACPS_RXSR_BUFFNA_MASK 0x01
#define XEMACPS_RXSR_HRESPNOK_MASK 0x08
#define XEMACPS_RXSR_RXOVR_MASK 0x10
#define XEMACPS_TXBUF_EXH_MASK 0x01
#define XEMACPS_TXBUF_LAST_MASK 0x02
#define XEMACPS_TXBUF_LEN_MASK 0x3fff
#define XEMACPS_TXBUF_NOCRC_MASK 0x04
#define XEMACPS_TXBUF_RETRY_MASK 0x08
#define XEMACPS_TXBUF_TCP_MASK 0x10
#define XEMACPS_TXBUF_URUN_MASK 0x20
#define XEMACPS_TXBUF_USED_MASK 0x40
#define XEMACPS_TXBUF_WRAP_MASK 0x80
#define XEMACPS_TXSR_BUFEXH_MASK 0x100
#define XEMACPS_TXSR_HRESPNOK_MASK 0x200
#define XEMACPS_TXSR_URUN_MASK 0x400
#define XEMACPS_TXSR_TXCOMPL_MASK 0x800
#define XEMACPS_TXSR_RXOVR_MASK 0x1000
#define XEMACPS_TXSR_FRAMERX_MASK 0x2000
#define XEMACPS_TXSR_USEDREAD_MASK 0x4000

/* ethernet.c defines XEMACPS_BD_TO_INDEX itself from these two fields. */

#define XEmacPs_GetRxRing(p) ((p)->rx)
#define XEmacPs_GetTxRing(p) ((p)->tx)

/* ---- injection hooks used by the tests ---------------------------- */
extern int mock_bdfree_fail_remaining;   /* >0: next N BdRingFree calls fail */
extern int mock_bdfree_calls;
extern int mock_bdfree_failed_calls;
void mock_ring_reset(void);
u32  mock_rx_free_count(void);
u32  mock_rx_stranded_count(void);   /* BDs left in 'post' */
u32  mock_rx_capacity(void);         /* BDs still in circulation */
u32  mock_rx_inflight(void);         /* BDs currently handed to hardware */
int  mock_rx_double_release(void);   /* 1 if a free-to-free release was seen */

/* ---- BD accessors ------------------------------------------------- */
void XEmacPs_BdClear(XEmacPs_Bd *bd);
void XEmacPs_BdClearRxNew(XEmacPs_Bd *bd);
void XEmacPs_BdClearTxUsed(XEmacPs_Bd *bd);
u32  XEmacPs_BdGetLength(XEmacPs_Bd *bd);
u32  XEmacPs_BdGetStatus(XEmacPs_Bd *bd);
void XEmacPs_BdSetAddressRx(XEmacPs_Bd *bd, void *addr);
void XEmacPs_BdSetAddressTx(XEmacPs_Bd *bd, void *addr);
void XEmacPs_BdSetLast(XEmacPs_Bd *bd);
void XEmacPs_BdSetLength(XEmacPs_Bd *bd, u32 len);
void XEmacPs_BdSetStatus(XEmacPs_Bd *bd, u32 st);

/* ---- ring API ----------------------------------------------------- */
LONG XEmacPs_BdRingCreate(XEmacPs_BdRing *r, UINTPTR phys, UINTPTR virt, u32 align, u32 cnt);
LONG XEmacPs_BdRingClone(XEmacPs_BdRing *r, XEmacPs_Bd *tmpl, u8 dir);
LONG XEmacPs_BdRingAlloc(XEmacPs_BdRing *r, u32 n, XEmacPs_Bd **bd);
LONG XEmacPs_BdRingToHw(XEmacPs_BdRing *r, u32 n, XEmacPs_Bd *bd);
u32  XEmacPs_BdRingFromHwRx(XEmacPs_BdRing *r, u32 n, XEmacPs_Bd **bd);
u32  XEmacPs_BdRingFromHwTx(XEmacPs_BdRing *r, u32 n, XEmacPs_Bd **bd);
LONG XEmacPs_BdRingFree(XEmacPs_BdRing *r, u32 n, XEmacPs_Bd *bd);
LONG XEmacPs_BdRingUnAlloc(XEmacPs_BdRing *r, u32 n, XEmacPs_Bd *bd);
u32  XEmacPs_BdRingGetFreeCnt(XEmacPs_BdRing *r);
XEmacPs_Bd *XEmacPs_BdRingNext(XEmacPs_BdRing *r, XEmacPs_Bd *bd);
u32  XEmacPs_BdRingMemCalc(u32 align, u32 cnt);

/* ---- device API (stubs) ------------------------------------------- */
XEmacPs_Config *XEmacPs_LookupConfig(u16 id);
LONG XEmacPs_CfgInitialize(XEmacPs *p, XEmacPs_Config *c, u32 base);
void XEmacPs_Start(XEmacPs *p);
void XEmacPs_Stop(XEmacPs *p);
void XEmacPs_IntEnable(XEmacPs *p, u32 m);
void XEmacPs_IntDisable(XEmacPs *p, u32 m);
u32  XEmacPs_ReadReg(u32 base, u32 off);
void XEmacPs_WriteReg(u32 base, u32 off, u32 val);
LONG XEmacPs_SetHandler(XEmacPs *p, u32 kind, void *fn, void *ref);
LONG XEmacPs_SetMacAddress(XEmacPs *p, void *mac, u8 idx);
void XEmacPs_SetMdioDivisor(XEmacPs *p, u32 d);
void XEmacPs_SetOperatingSpeed(XEmacPs *p, u16 s);
LONG XEmacPs_PhyRead(XEmacPs *p, u32 addr, u32 reg, u16 *val);
LONG XEmacPs_PhyWrite(XEmacPs *p, u32 addr, u32 reg, u16 val);
LONG XEmacPs_Transmit(XEmacPs *p);
LONG XEmacPs_SendPausePacket(XEmacPs *p);
void XEmacPs_IntrHandler(void *p);
#endif
