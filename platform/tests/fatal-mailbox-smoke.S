/* Protocol transport test only; does not claim to exercise OpenSBI handlers. */
#include "linuxcpu_diag.h"
    .section .text
    .globl _start
_start:
    li t0, 0x30013
    csrs 0x7c2, t0
    li t0, 0x7f
    csrs 0x7c1, t0
    fence.i
    /* Leave an unrelated ordinary RAM write in the enabled D-cache. */
    li t0, 0x20000
    li t1, 0x123456789abcdef0
    sd t1, 0(t0)
    li t0, LINUXCPU_DIAG_BASE
    sd zero, 72(t0)
    fence iorw, iorw
    li t1, -7
    sd t1, 0(t0)
    li t1, 2
    sd t1, 8(t0)
    li t1, 0xdeadbeef
    sd t1, 16(t0)
    sd zero, 24(t0)
    sd zero, 32(t0)
    li t1, 0x11223344
    sd t1, 40(t0)
    csrr t1, mstatus
    sd t1, 48(t0)
    li t1, 0x55667788
    sd t1, 56(t0)
    li t1, 0x9900
    sd t1, 64(t0)
    fence iorw, iorw
#ifndef DIAG_PARTIAL
    li t1, LINUXCPU_DIAG_TRAP_MAGIC
    sd t1, 72(t0)
    fence iorw, iorw
#endif
    /* Keep retiring: detection must not rely on the no-retirement watchdog. */
1:  j 1b
