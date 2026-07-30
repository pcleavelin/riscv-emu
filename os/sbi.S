# The kernel's own escape hatch to the host.
#
# An ecall from supervisor mode leaves the machine instead of trapping into
# stvec, so this is the one call that reaches the emulator. Compare trap.S,
# whose do_syscall is the same instruction made from user mode and lands in the
# kernel; the two numbering spaces are therefore independent.

.section .text

# sbi_call(number, arg0, arg1, arg2) -> result
#
# The C ABI hands the number in a0 and the arguments in a1..a3, while the SBI
# convention wants the number in a7 and the arguments in a0..a2. Shuffle through
# t0 because a0 is both the first argument and the result register.
.globl sbi_call
sbi_call:
    mv      t0, a0
    mv      a0, a1
    mv      a1, a2
    mv      a2, a3
    mv      a7, t0
    ecall
    ret
