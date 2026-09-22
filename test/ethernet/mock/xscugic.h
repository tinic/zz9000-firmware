#ifndef MOCK_XSCUGIC_H
#define MOCK_XSCUGIC_H
#include "platform.h"
typedef struct { int dummy; } XScuGic;
typedef struct { int dummy; } XScuGic_Config;
static inline XScuGic_Config *XScuGic_LookupConfig(u16 id) { (void)id; static XScuGic_Config c; return &c; }
static inline int XScuGic_CfgInitialize(XScuGic *g, XScuGic_Config *c, u32 b) { (void)g;(void)c;(void)b; return 0; }
static inline int XScuGic_Connect(XScuGic *g, u32 i, void *h, void *r) { (void)g;(void)i;(void)h;(void)r; return 0; }
static inline void XScuGic_Enable(XScuGic *g, u32 i) { (void)g;(void)i; }
static inline void XScuGic_SetPriorityTriggerType(XScuGic *g, u32 i, u8 p, u8 t) { (void)g;(void)i;(void)p;(void)t; }
static inline void Xil_ExceptionEnable(void) {}
static inline void Xil_ExceptionInit(void) {}
static inline void Xil_ExceptionRegisterHandler(u32 i, void *h, void *d) { (void)i;(void)h;(void)d; }
#define XIL_EXCEPTION_ID_INT 5
#endif
