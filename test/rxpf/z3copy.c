/*
 * z3copy: packet-sized copy timing from a source (ZZ9000 card memory or
 * Fast RAM) into Fast RAM, destination aligned and at +2 (the driver's
 * IP-header offset).  E-clock under Forbid() (interrupts stay on), best of
 * REPS, ITER copies per sample.  Reads the source only; writes only its own
 * Fast RAM buffers, whose guard bytes are checked after every method.
 *
 *   z3copy ADDR=<hex> [LEN=1512] [ITER=64] [REPS=5]   source on the card
 *   z3copy FAST [LEN=1512] ...                        Fast RAM source control
 *
 * Methods: movem = the driver's n68k_copy_longs (four movem pairs per
 * 128-byte block, scalar tail); movel = 32 unrolled move.l per block;
 * move16 = 68040/060 line moves, only when source and destination are both
 * 16-byte aligned (never at dst+2).
 */
#include <exec/types.h>
#include <exec/memory.h>
#include <exec/execbase.h>
#include <devices/timer.h>
#include <dos/dos.h>
#include <proto/exec.h>
#include <proto/dos.h>
#include <proto/timer.h>

struct Device *TimerBase;
extern struct ExecBase *SysBase;

#define GUARD 32

static ULONG strtoul_hex(const char *s)
{
    ULONG v = 0;
    if (*s == '$') s++;
    else if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) s += 2;
    for (; *s; s++) {
        char c = *s;
        v <<= 4;
        if (c >= '0' && c <= '9') v |= (ULONG)(c - '0');
        else if (c >= 'a' && c <= 'f') v |= (ULONG)(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') v |= (ULONG)(c - 'A' + 10);
        else break;
    }
    return v;
}

/* The driver's loop, verbatim apart from the calling convention. */
static void cp_movem(UBYTE *to, const volatile UBYTE *from, ULONG longs)
{
    ULONG blocks = longs >> 5, rest = longs & 31;
    if (blocks)
        __asm__ volatile(
            "1:\n\t"
            "movem.l (%1)+,%%d0-%%d5/%%a2-%%a3\n\t movem.l %%d0-%%d5/%%a2-%%a3,(%0)\n\t"
            "movem.l (%1)+,%%d0-%%d5/%%a2-%%a3\n\t movem.l %%d0-%%d5/%%a2-%%a3,32(%0)\n\t"
            "movem.l (%1)+,%%d0-%%d5/%%a2-%%a3\n\t movem.l %%d0-%%d5/%%a2-%%a3,64(%0)\n\t"
            "movem.l (%1)+,%%d0-%%d5/%%a2-%%a3\n\t movem.l %%d0-%%d5/%%a2-%%a3,96(%0)\n\t"
            "lea 128(%0),%0\n\t"
            "subq.l #1,%2\n\t bne.w 1b"
            : "+a"(to), "+a"(from), "+d"(blocks)
            : : "d0", "d1", "d2", "d3", "d4", "d5", "a2", "a3", "memory", "cc");
    while (rest--) {
        *(ULONG *)to = *(const volatile ULONG *)from;
        to += 4; from += 4;
    }
}

static void cp_movel(UBYTE *to, const volatile UBYTE *from, ULONG longs)
{
    ULONG blocks = longs >> 5, rest = longs & 31;
    if (blocks)
        __asm__ volatile(
            "1:\n\t"
            ".rept 32\n\t move.l (%1)+,(%0)+\n\t .endr\n\t"
            "subq.l #1,%2\n\t bne.w 1b"
            : "+a"(to), "+a"(from), "+d"(blocks) : : "memory", "cc");
    while (rest--) {
        *(ULONG *)to = *(const volatile ULONG *)from;
        to += 4; from += 4;
    }
}

static void cp_move16(UBYTE *to, const volatile UBYTE *from, ULONG longs)
{
    ULONG lines = longs >> 2, rest = longs & 3;
    if (lines)
        __asm__ volatile(
            "1:\n\t"
            "move16 (%1)+,(%0)+\n\t"
            "subq.l #1,%2\n\t bne.w 1b"
            : "+a"(to), "+a"(from), "+d"(lines) : : "memory", "cc");
    while (rest--) {
        *(ULONG *)to = *(const volatile ULONG *)from;
        to += 4; from += 4;
    }
}

typedef void (*copyfn)(UBYTE *, const volatile UBYTE *, ULONG);

int main(void)
{
    LONG args[6] = { 0, 0, 0, 0, 0, 0 };
    struct RDArgs *rd;
    struct timerequest tr;
    struct EClockVal t0, t1;
    const volatile UBYTE *src;
    UBYTE *dbuf, *snap, *own = NULL;
    ULONG len, iter, reps, hz = 0, i, m, o, r, longs, alloc;
    int has040 = (SysBase->AttnFlags & (AFF_68040 | 0x80)) != 0; /* 0x80 = AFF_68060 */
    static const char *const mname[3] = { "movem ", "movel ", "move16" };
    static const copyfn fn[3] = { cp_movem, cp_movel, cp_move16 };
    static const ULONG offs[2] = { 0, 2 };

    rd = ReadArgs("ADDR/K,FAST/S,LEN/K/N,ITER/K/N,REPS/K/N", args, NULL);
    if (rd == NULL) { PrintFault(IoErr(), "z3copy"); return 10; }
    len = args[2] ? *(LONG *)args[2] : 1512;
    iter = args[3] ? *(LONG *)args[3] : 64;
    reps = args[4] ? *(LONG *)args[4] : 5;
    len &= ~3ul;
    longs = len / 4;
    alloc = len + 2 * GUARD + 16;

    if (args[1]) {
        own = AllocMem(len + 16, MEMF_FAST);
        if (own == NULL) { Printf("z3copy: no fast memory\n"); FreeArgs(rd); return 10; }
        src = (const volatile UBYTE *)(((ULONG)own + 15) & ~15ul);
        for (i = 0; i < len; i++) ((UBYTE *)src)[i] = (UBYTE)(i * 7 + 3);
    } else if (args[0]) {
        src = (const volatile UBYTE *)strtoul_hex((const char *)args[0]);
    } else {
        Printf("z3copy: ADDR or FAST\n"); FreeArgs(rd); return 10;
    }
    dbuf = AllocMem(alloc, MEMF_FAST);
    snap = AllocMem(len, MEMF_FAST);
    if (dbuf == NULL || snap == NULL) { Printf("z3copy: no fast memory\n"); return 10; }
    if (OpenDevice((STRPTR)TIMERNAME, UNIT_ECLOCK, (struct IORequest *)&tr, 0)) {
        Printf("z3copy: no timer\n"); return 10;
    }
    TimerBase = tr.tr_node.io_Device;

    Printf("z3copy src $%08lx len %lu iter %lu reps %lu cpu040+ %ld\n",
           (ULONG)src, len, iter, reps, (LONG)has040);
    for (m = 0; m < 3; m++) {
        for (o = 0; o < 2; o++) {
            UBYTE *base = (UBYTE *)(((ULONG)dbuf + GUARD + 15) & ~15ul);
            UBYTE *dst = base + offs[o];
            ULONG best = 0xfffffffful, bad = 0, guardbad = 0;
            if (m == 2 && (!has040 || offs[o] != 0 || ((ULONG)src & 15))) continue;
            for (i = 0; i < alloc; i++) dbuf[i] = 0xA5;
            for (r = 0; r < reps; r++) {
                ULONG t;
                Forbid();
                hz = ReadEClock(&t0);
                for (i = 0; i < iter; i++) fn[m](dst, src, longs);
                ReadEClock(&t1);
                Permit();
                t = t1.ev_lo - t0.ev_lo;
                if (t < best) best = t;
            }
            /* Verify: snapshot the source with a plain longword loop right
             * after one more copy; a live RX window may change between. */
            Forbid();
            fn[m](dst, src, longs);
            cp_movel(snap, src, longs);
            Permit();
            for (i = 0; i < len; i++) if (dst[i] != snap[i]) bad++;
            for (i = 0; i < (ULONG)(dst - dbuf); i++) if (dbuf[i] != 0xA5) guardbad++;
            for (i = (ULONG)(dst - dbuf) + len; i < alloc; i++) if (dbuf[i] != 0xA5) guardbad++;
            {
                unsigned long long bytes = (unsigned long long)len * iter;
                ULONG kbs = (ULONG)((bytes * hz) / best / 1000);
                ULONG ns_x10 = (ULONG)(((unsigned long long)best * 10000000000ull) / hz / (bytes / 4));
                ULONG us_x10 = (ULONG)(((unsigned long long)best * 10000000ull) / hz / iter);
                Printf("  %s dst+%lu  %lu.%lu us/copy  %lu.%lu ns/long  %lu KB/s  mismatch %lu guard %lu\n",
                       (ULONG)mname[m], offs[o], us_x10 / 10, us_x10 % 10,
                       ns_x10 / 10, ns_x10 % 10, kbs, bad, guardbad);
            }
        }
    }
    CloseDevice((struct IORequest *)&tr);
    FreeMem(snap, len);
    FreeMem(dbuf, alloc);
    if (own) FreeMem(own, len + 16);
    FreeArgs(rd);
    return 0;
}
