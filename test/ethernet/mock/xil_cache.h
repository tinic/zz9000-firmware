#ifndef MOCK_XIL_CACHE_H
#define MOCK_XIL_CACHE_H
#include "platform.h"
static inline void Xil_DCacheFlushRange(UINTPTR a, u32 l) { (void)a; (void)l; }
static inline void Xil_DCacheInvalidateRange(UINTPTR a, u32 l) { (void)a; (void)l; }
static inline void Xil_L2CacheInvalidateRange(UINTPTR a, u32 l) { (void)a; (void)l; }
#endif
