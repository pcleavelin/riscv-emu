/*
 * The user side of the syscall boundary.
 *
 * An app links its own copy of this: it cannot call the kernel's, because the
 * supervisor's pages are not reachable from user mode. From user mode the ecall
 * traps into the kernel rather than out to the host.
 */

.section .text.do_syscall, "ax", @progbits
.globl do_syscall
.type do_syscall, @function
.align 2

/* i64 do_syscall(u64 number, u64 arg0, u64 arg1) */
do_syscall:
    mv   a7, a0
    mv   a0, a1
    mv   a1, a2
    ecall
    ret
    .size do_syscall, . - do_syscall
