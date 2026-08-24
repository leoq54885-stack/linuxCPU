/*
 * Directed C906 CLINT smoke.  Keep this sequence identical to OpenSBI's
 * RV32-compatible mtimecmp update: low=-1, high=value>>32, low=value.
 *
 * Define CLINT_FENCE_BETWEEN_WRITES to test the conservative workaround.
 * The smart_run testbench watches the two magic register values below.
 */

#ifdef CLINT_FENCE_BETWEEN_WRITES
#define CLINT_WRITE_BARRIER fence iorw, iorw
#else
#define CLINT_WRITE_BARRIER
#endif

    .section .text.init
    .globl _start
    .align 2
_start:
    li      t0, 0x4004004000
#ifdef CLINT_SINGLE_64BIT_STORE
    li      t1, 0x12345678
    sd      t1, 0(t0)
#else
    li      t1, -1
    sw      t1, 0(t0)
    CLINT_WRITE_BARRIER
    sw      zero, 4(t0)
    CLINT_WRITE_BARRIER
    li      t1, 0x12345678
    sw      t1, 0(t0)
#endif
    fence   iorw, iorw

    lw      t2, 0(t0)
    lw      t3, 4(t0)
    li      t4, 0x12345678
    bne     t2, t4, .Lfail
    bnez    t3, .Lfail

    li      t6, 0x444333222
.Lpass_loop:
    j       .Lpass_loop

.Lfail:
    li      t6, 0x2382348720
.Lfail_loop:
    j       .Lfail_loop
