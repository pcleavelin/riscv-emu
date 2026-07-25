package abi

// The kernel/user contract. Both the kernel and the app SDK import this, so the
// two sides cannot drift apart: a syscall number or a struct layout exists once.

// --- User address space --------------------------------------------------------
//
// The kernel occupies 0x8000_0000 upward and identity maps itself there, so the
// low half of every address space belongs to the process. Because each process
// has its own page table, every app links at the same base.

USER_TEXT_BASE :: 0x0001_0000 // where an app image is linked and mapped

USER_HEAP_BASE :: 0x2000_0000
USER_HEAP_SIZE :: 1024 * 1024

USER_STACK_TOP :: 0x4000_0000 // grows down
USER_STACK_SIZE :: 64 * 1024

// --- Syscalls ------------------------------------------------------------------
//
// Number in a7, arguments in a0 and a1, result in a0. A result of zero or more is
// success; negative is one of the errors below.

SYS_EXIT :: 1
SYS_YIELD :: 2
SYS_SEND :: 3
SYS_RECV :: 4
SYS_TRY_RECV :: 5
SYS_SPAWN :: 6
SYS_LOG :: 7
SYS_SELF :: 8

OK :: 0
ERR_FAULT :: -1    // a pointer argument was not usable by this process
ERR_NO_PROC :: -2  // no such process
ERR_FULL :: -3     // the target mailbox refused the message
ERR_EMPTY :: -4    // nothing to receive
ERR_BAD_CALL :: -5 // unknown syscall

// --- Messages ------------------------------------------------------------------

TAG_MAX :: 16
DATA_MAX :: 64

// How a message crosses the boundary: one fixed-size struct passed by pointer, so
// the kernel has exactly one shape to validate and copy. Anything larger than
// DATA_MAX belongs in a shared memory grant rather than a message.
MessageBuf :: struct {
    from:     i64,
    tag_len:  i64,
    data_len: i64,
    tag:      [TAG_MAX]u8,
    data:     [DATA_MAX]u8,
}
