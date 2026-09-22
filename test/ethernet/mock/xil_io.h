#ifndef MOCK_XIL_IO_H
#define MOCK_XIL_IO_H
#include "platform.h"
static inline u32 Xil_In32(uintptr_t a) { (void)a; return 0; }
static inline void Xil_Out32(uintptr_t a, u32 v) { (void)a; (void)v; }
#endif
