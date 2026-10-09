#!/usr/bin/env python3
"""Check that z3copy rejects a failed copy verification instead of printing
timings. Builds the probe's main() on the host with the copy routines, Exec,
DOS and timer stubbed, then injects mismatches, guard hits, bad arguments and
allocation/timer failures. Does not run the m68k copy loops."""
import argparse
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True

# case -> (exit code, metric lines)
CASES = {
    "normal": (0, 5), "mismatch": (20, 0), "guard": (20, 0),
    "len0": (10, 0), "iter0": (10, 0), "reps0": (10, 0),
    "alloc1": (10, 0), "alloc2": (10, 0), "alloc3": (10, 0),
    "timer_open": (10, 0), "ticks0": (10, 0), "hz0": (10, 0),
}


def fixture(s):
    s=re.sub(r'^#include <[^>]+>\n','',s,flags=re.M)
    a=s.index('/* Link the exact shipping');b=s.index('typedef void (*copyfn)',a)
    s=s[:a]+'''static void cp_movem(UBYTE *to,const volatile UBYTE *from,ULONG longs) {
     memcpy(to,(const void *)from,longs*4);
     if (!strcmp(test_case,"mismatch")) to[0]^=1;
     if (!strcmp(test_case,"guard")) to[-1]=0;
    }
    static void cp_movel(UBYTE *to,const volatile UBYTE *from,ULONG longs) {memcpy(to,(const void *)from,longs*4);}
    static void cp_move16(UBYTE *to,const volatile UBYTE *from,ULONG longs) {memcpy(to,(const void *)from,longs*4);}

    '''+s[b:]
    s=s.replace('int main(void)','static int bench_main(void)')
    shim=r'''
    #define _GNU_SOURCE
    #include <stdint.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <assert.h>
    #include <sys/mman.h>
    typedef unsigned char UBYTE;
    typedef uintptr_t ULONG;
    typedef intptr_t LONG;
    typedef unsigned char *STRPTR;
    typedef const unsigned char *CONST_STRPTR;
    struct Device {int value;};
    struct IORequest {struct Device *io_Device;};
    struct timerequest {struct IORequest tr_node;};
    struct EClockVal {ULONG ev_hi,ev_lo;};
    struct RDArgs {int value;};
    struct ExecBase {unsigned AttnFlags;};
    #define AFF_68040 64
    #define MEMF_FAST 1
    #define TIMERNAME "timer.device"
    #define UNIT_ECLOCK 1
    static const char *test_case;
    static unsigned alloc_calls,live_alloc,closes,opens,forbids,permits,args_freed,metric_lines;
    static struct Device timer_device;
    static struct RDArgs rdargs;
    static struct ExecBase execbase={64};
    struct ExecBase *SysBase=&execbase;
    static LONG arg_len=1512,arg_iter=64,arg_reps=5;
    static struct RDArgs *ReadArgs(CONST_STRPTR text,LONG *args,void *unused) {
     (void)text;(void)unused;
     args[1]=1;
     if(!strcmp(test_case,"len0"))arg_len=0;
     if(!strcmp(test_case,"iter0"))arg_iter=0;
     if(!strcmp(test_case,"reps0"))arg_reps=0;
     args[2]=(LONG)&arg_len;args[3]=(LONG)&arg_iter;args[4]=(LONG)&arg_reps;
     return &rdargs;
    }
    static void FreeArgs(struct RDArgs *rd){assert(rd==&rdargs);args_freed++;}
    static LONG IoErr(void){return 0;}
    static void PrintFault(LONG err,CONST_STRPTR msg){(void)err;(void)msg;}
    static void Printf(CONST_STRPTR text,...) {
     if(text[0]==' '&&text[1]==' ')metric_lines++;
    }
    static void *AllocMem(ULONG bytes,ULONG flags) {
     (void)flags;alloc_calls++;
     if((!strcmp(test_case,"alloc1")&&alloc_calls==1)||(!strcmp(test_case,"alloc2")&&alloc_calls==2)||(!strcmp(test_case,"alloc3")&&alloc_calls==3))return NULL;
     void *p=mmap(NULL,bytes,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS|MAP_32BIT,-1,0);
     assert(p!=MAP_FAILED && (uintptr_t)p<=UINT32_MAX);live_alloc++;return p;
    }
    static void FreeMem(void *p,ULONG bytes){assert(p&&live_alloc);assert(munmap(p,bytes)==0);live_alloc--;}
    static LONG OpenDevice(STRPTR name,ULONG unit,struct IORequest *req,ULONG flags) {
     (void)name;(void)unit;(void)flags;
     if(!strcmp(test_case,"timer_open"))return 1;
     opens++;req->io_Device=&timer_device;return 0;
    }
    static void CloseDevice(struct IORequest *req){assert(req->io_Device==&timer_device);closes++;}
    static void Forbid(void){forbids++;}
    static void Permit(void){permits++;}
    static ULONG ReadEClock(struct EClockVal *t) {
     static ULONG ticks;
     if(strcmp(test_case,"ticks0"))ticks+=100;
     t->ev_lo=ticks;t->ev_hi=0;
     return !strcmp(test_case,"hz0")?0:710000;
    }
    '''
    end=r'''
    int main(int argc,char **argv) {
     assert(argc==2);test_case=argv[1];
     int result=bench_main();
     assert(!live_alloc && opens==closes && forbids==permits && args_freed==1);
     printf("case=%s rc=%d metric_lines=%u cleanup=PASS\n",test_case,result,metric_lines);
     return result;
    }
    '''
    return shim+s+end


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cc", default="clang")
    parser.add_argument("case", nargs="?", choices=["all"] + list(CASES), default="all")
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    failed = 0
    with tempfile.TemporaryDirectory(prefix="z3copy-", dir=here) as build:
        generated = Path(build) / "z3copy_host.c"
        generated.write_text(fixture((here / "z3copy.c").read_text()))
        output = Path(build) / "z3copy_host"
        subprocess.run([args.cc, "-std=gnu11", "-Wall", "-Wextra", "-Werror", "-O1", "-g",
                        "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                        str(generated), "-o", str(output)], check=True)
        for case in CASES if args.case == "all" else [args.case]:
            run = subprocess.run([str(output), case], capture_output=True, text=True)
            want_rc, want_lines = CASES[case]
            ok = (run.returncode == want_rc and
                  "metric_lines=%d cleanup=PASS" % want_lines in run.stdout)
            print("%s %s rc=%d %s" % ("PASS" if ok else "FAIL", case, run.returncode,
                                      run.stdout.strip() or run.stderr.strip()[-300:]))
            failed += not ok
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
