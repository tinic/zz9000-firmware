#ifndef MOCK_INTERRUPT_H
#define MOCK_INTERRUPT_H
#include "platform.h"
#include "xscugic.h"
typedef void (*Xil_InterruptHandler)(void *);
XScuGic *interrupt_get_intc(void);
#define AMIGA_INTERRUPT_ETH 1
static inline void amiga_interrupt_set(u32 m) { (void)m; }
static inline void amiga_interrupt_clear(u32 m) { (void)m; }
#endif
