#ifndef MOCK_MNTZORRO_H
#define MOCK_MNTZORRO_H
#include "platform.h"
#include "xil_io.h"
#define MNTZ_BASE_ADDR 0
#define MNTZORRO_REG4  4
extern u32 mock_reg4_last;
void mntzorro_write(u32 base, u32 reg, u32 val);
u32  mntzorro_read(u32 base, u32 reg);
#endif
