/*
 * Supervisor trap entry and the transitions in and out of user mode.
 *
 * A trap arrives with sp still pointing at the *user* stack, so the first thing
 * trap_entry does is swap it with sscratch, which holds the kernel stack. The
 * whole integer register file is then saved into a TrapFrame, indexed by register
 * number so the Odin handler can read a7/a0/a1 by name, followed by sepc and
 * sstatus.
 *
 * The kernel stack a user process traps onto is its own fiber stack, so the frame
 * built here survives a syscall that blocks: the handler switches away mid-trap
 * and the frame stays where it is until the scheduler resumes that process.
 */

.equ TRAPFRAME_SIZE, 34*8
.equ FRAME_SEPC,     32*8
.equ FRAME_SSTATUS,  33*8

.section .text.trap_entry, "ax", @progbits
.globl trap_entry
.type trap_entry, @function
.align 4

trap_entry:
    /* sscratch holds the kernel stack while user code runs, and zero while the
     * kernel runs. So after the swap a zero sp means this trap came from the
     * kernel, which is already on the right stack and must swap back. */
    csrrw sp, sscratch, sp
    bnez  sp, .Lfrom_user

    csrrw sp, sscratch, sp          /* kernel trap: restore sp, sscratch back to 0 */
    addi  sp, sp, -TRAPFRAME_SIZE
    sd    x5,   5*8(sp)
    addi  x5, sp, TRAPFRAME_SIZE    /* the sp we interrupted */
    sd    x5,   2*8(sp)
    j     .Lsaved_sp

.Lfrom_user:
    addi  sp, sp, -TRAPFRAME_SIZE
    sd    x5,   5*8(sp)             /* free up t0 before we need a scratch */
    csrr  x5, sscratch              /* recover the user sp ... */
    sd    x5,   2*8(sp)             /* ... and record it in the frame */
    csrw  sscratch, zero            /* we are in the kernel now */

.Lsaved_sp:
    sd    x1,   1*8(sp)
    sd    x3,   3*8(sp)
    sd    x4,   4*8(sp)
    sd    x6,   6*8(sp)
    sd    x7,   7*8(sp)
    sd    x8,   8*8(sp)
    sd    x9,   9*8(sp)
    sd    x10, 10*8(sp)
    sd    x11, 11*8(sp)
    sd    x12, 12*8(sp)
    sd    x13, 13*8(sp)
    sd    x14, 14*8(sp)
    sd    x15, 15*8(sp)
    sd    x16, 16*8(sp)
    sd    x17, 17*8(sp)
    sd    x18, 18*8(sp)
    sd    x19, 19*8(sp)
    sd    x20, 20*8(sp)
    sd    x21, 21*8(sp)
    sd    x22, 22*8(sp)
    sd    x23, 23*8(sp)
    sd    x24, 24*8(sp)
    sd    x25, 25*8(sp)
    sd    x26, 26*8(sp)
    sd    x27, 27*8(sp)
    sd    x28, 28*8(sp)
    sd    x29, 29*8(sp)
    sd    x30, 30*8(sp)
    sd    x31, 31*8(sp)

    /* t0 is already saved, so it is free to carry the CSRs into the frame. */
    csrr  t0, sepc
    sd    t0, FRAME_SEPC(sp)
    csrr  t0, sstatus
    sd    t0, FRAME_SSTATUS(sp)

    mv    a0, sp                    /* hand the frame to the handler */
    call  trap_handler

    /* sepc and sstatus come back from the frame, not from the CSRs: a syscall
     * that blocked let other processes run, and their own traps overwrote both.
     * The handler adjusts the frame's copy of sepc, never the register. */
    ld    t0, FRAME_SEPC(sp)
    csrw  sepc, t0
    ld    t0, FRAME_SSTATUS(sp)
    csrw  sstatus, t0

    /* Leave sscratch holding what the mode we return to expects: the kernel
     * stack if user code is about to run, zero if we stay in the kernel. */
    andi  t0, t0, (1 << 8)          /* SPP, as just restored */
    bnez  t0, .Lto_kernel
    addi  t0, sp, TRAPFRAME_SIZE
    csrw  sscratch, t0
    j     .Lrestore
.Lto_kernel:
    csrw  sscratch, zero

.Lrestore:
    ld    x1,   1*8(sp)
    ld    x3,   3*8(sp)
    ld    x4,   4*8(sp)
    ld    x5,   5*8(sp)
    ld    x6,   6*8(sp)
    ld    x7,   7*8(sp)
    ld    x8,   8*8(sp)
    ld    x9,   9*8(sp)
    ld    x10, 10*8(sp)
    ld    x11, 11*8(sp)
    ld    x12, 12*8(sp)
    ld    x13, 13*8(sp)
    ld    x14, 14*8(sp)
    ld    x15, 15*8(sp)
    ld    x16, 16*8(sp)
    ld    x17, 17*8(sp)
    ld    x18, 18*8(sp)
    ld    x19, 19*8(sp)
    ld    x20, 20*8(sp)
    ld    x21, 21*8(sp)
    ld    x22, 22*8(sp)
    ld    x23, 23*8(sp)
    ld    x24, 24*8(sp)
    ld    x25, 25*8(sp)
    ld    x26, 26*8(sp)
    ld    x27, 27*8(sp)
    ld    x28, 28*8(sp)
    ld    x29, 29*8(sp)
    ld    x30, 30*8(sp)
    ld    x31, 31*8(sp)

    ld    x2,   2*8(sp)             /* sp last: it is also the frame's base */
    sret
    .size trap_entry, . - trap_entry

/*
 * void user_enter(u64 entry, u64 user_sp)
 *
 * Drop to user mode at `entry` on `user_sp`. Clearing sstatus.SPP is what makes
 * the sret land in U-mode rather than back in S-mode, and sscratch takes the
 * stack we are leaving -- the calling fiber's own -- for trap_entry to swap in.
 *
 * This never returns. Control comes back only as a trap, which resumes at the
 * sret's own frame through trap_entry, and a process leaves user mode for good
 * only by exiting, which switches to the scheduler instead.
 */
.section .text.user_enter, "ax", @progbits
.globl user_enter
.type user_enter, @function
.align 2

user_enter:
    csrw sepc, a0                   /* sret resumes here, in user mode */
    li   t0, (1 << 8)
    csrc sstatus, t0                /* SPP = 0 -> return to user */
    csrw sscratch, sp               /* the stack trap_entry will swap in */
    mv   sp, a1                     /* user stack */
    sret
    .size user_enter, . - user_enter

/*
 * u64 do_syscall(u64 number, u64 arg0, u64 arg1)
 *
 * The user-side syscall stub: move the arguments into the ABI registers and
 * ecall. From user mode that traps into the kernel rather than reaching the host.
 */
.section .text.do_syscall, "ax", @progbits
.globl do_syscall
.type do_syscall, @function
.align 2

do_syscall:
    mv   a7, a0
    mv   a0, a1
    mv   a1, a2
    ecall
    ret
    .size do_syscall, . - do_syscall

/* Small accessors so the Odin handler can touch the CSRs it needs. */
.section .text.csr_access, "ax", @progbits

.globl csr_read_scause
csr_read_scause:
    csrr a0, scause
    ret

.globl csr_read_stval
csr_read_stval:
    csrr a0, stval
    ret

.globl csr_write_stvec
csr_write_stvec:
    csrw stvec, a0
    ret

.globl csr_write_satp
csr_write_satp:
    csrw satp, a0
    sfence.vma
    ret

.globl csr_read_satp
csr_read_satp:
    csrr a0, satp
    ret

/*
 * Bracket accesses to user memory. Between these the kernel may load and store
 * through user mappings; outside them a stray user-pointer dereference faults,
 * which is the point of keeping the window narrow.
 */
.globl user_access_begin
user_access_begin:
    li   t0, (1 << 18)              /* sstatus.SUM */
    csrs sstatus, t0
    ret

.globl user_access_end
user_access_end:
    li   t0, (1 << 18)
    csrc sstatus, t0
    ret
