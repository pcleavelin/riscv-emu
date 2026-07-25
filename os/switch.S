/*
 * Cooperative context switch for fiber tasks.
 *
 * Only the callee-saved registers need saving: by the RISC-V calling convention
 * the caller of ctx_switch already treats everything else as clobbered across a
 * call. That is ra, sp, s0-s11, and fs0-fs11 -- laid out to match the Context
 * struct in kernel.odin (26 slots of 8 bytes).
 */

.section .text.ctx_switch, "ax", @progbits
.globl ctx_switch
.type ctx_switch, @function
.align 2

/* void ctx_switch(Context *from, Context *to); a0 = from, a1 = to */
ctx_switch:
    sd   ra,   0*8(a0)
    sd   sp,   1*8(a0)
    sd   s0,   2*8(a0)
    sd   s1,   3*8(a0)
    sd   s2,   4*8(a0)
    sd   s3,   5*8(a0)
    sd   s4,   6*8(a0)
    sd   s5,   7*8(a0)
    sd   s6,   8*8(a0)
    sd   s7,   9*8(a0)
    sd   s8,  10*8(a0)
    sd   s9,  11*8(a0)
    sd   s10, 12*8(a0)
    sd   s11, 13*8(a0)
    fsd  fs0, 14*8(a0)
    fsd  fs1, 15*8(a0)
    fsd  fs2, 16*8(a0)
    fsd  fs3, 17*8(a0)
    fsd  fs4, 18*8(a0)
    fsd  fs5, 19*8(a0)
    fsd  fs6, 20*8(a0)
    fsd  fs7, 21*8(a0)
    fsd  fs8, 22*8(a0)
    fsd  fs9, 23*8(a0)
    fsd  fs10,24*8(a0)
    fsd  fs11,25*8(a0)

    ld   ra,   0*8(a1)
    ld   sp,   1*8(a1)
    ld   s0,   2*8(a1)
    ld   s1,   3*8(a1)
    ld   s2,   4*8(a1)
    ld   s3,   5*8(a1)
    ld   s4,   6*8(a1)
    ld   s5,   7*8(a1)
    ld   s6,   8*8(a1)
    ld   s7,   9*8(a1)
    ld   s8,  10*8(a1)
    ld   s9,  11*8(a1)
    ld   s10, 12*8(a1)
    ld   s11, 13*8(a1)
    fld  fs0, 14*8(a1)
    fld  fs1, 15*8(a1)
    fld  fs2, 16*8(a1)
    fld  fs3, 17*8(a1)
    fld  fs4, 18*8(a1)
    fld  fs5, 19*8(a1)
    fld  fs6, 20*8(a1)
    fld  fs7, 21*8(a1)
    fld  fs8, 22*8(a1)
    fld  fs9, 23*8(a1)
    fld  fs10,24*8(a1)
    fld  fs11,25*8(a1)

    /* Resume at the restored ra: either the point a task last switched away
     * from, or fiber_trampoline for a task that has never run. */
    ret
    .size ctx_switch, . - ctx_switch

/*
 * First-run entry for a fiber. spawn_task seeds the context with ra pointing
 * here and s0 holding the Process pointer, so the first ctx_switch into a task
 * "returns" into this stub with an empty stack.
 */
.section .text.fiber_trampoline, "ax", @progbits
.globl fiber_trampoline
.type fiber_trampoline, @function
.align 2

fiber_trampoline:
    mv   a0, s0
    call fiber_main
    /* fiber_main switches away for good once the task exits, so this is
     * unreachable; trap rather than run off into whatever follows. */
    li   a7, 0xFF
    li   a0, 0xDEAD
    ecall
    .size fiber_trampoline, . - fiber_trampoline
