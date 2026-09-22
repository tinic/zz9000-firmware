#ifndef MOCK_XIL_MMU_H
#define MOCK_XIL_MMU_H
#include "platform.h"
static inline void Xil_SetTlbAttributes(u32 a, u32 a2) { (void)a; (void)a2; }
#define STRONG_ORDERED 0xc02u
#endif
