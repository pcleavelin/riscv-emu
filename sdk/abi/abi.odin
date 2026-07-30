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

// Where a granted buffer appears. The region is cut into equal slots so a grant
// always lands slot-aligned, which is what lets the kernel hand one to a process
// without either side negotiating an address.
GRANT_BASE :: 0x3000_0000
GRANT_SLOT_SIZE :: 1024 * 1024
GRANT_SLOTS :: 8 // how many grants one process may hold mapped at once

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
SYS_GRANT_CREATE :: 9
SYS_GRANT_MAP :: 10
SYS_GRANT_DROP :: 11
SYS_PRESENT :: 12      // show a grant's contents on the display
SYS_DISPLAY_INFO :: 13 // -> width in the high 32 bits, height in the low

OK :: 0
ERR_FAULT :: -1    // a pointer argument was not usable by this process
ERR_NO_PROC :: -2  // no such process
ERR_FULL :: -3     // the target mailbox refused the message
ERR_EMPTY :: -4    // nothing to receive
ERR_BAD_CALL :: -5 // unknown syscall
ERR_NO_GRANT :: -6 // no such grant, or it does not belong to this process
ERR_NO_SPACE :: -7 // no free grant slot, or the request is too large

// --- Messages ------------------------------------------------------------------

TAG_MAX :: 16
DATA_MAX :: 64

NO_GRANT :: -1 // a message that carries no grant

// How a message crosses the boundary: one fixed-size struct passed by pointer, so
// the kernel has exactly one shape to validate and copy. Anything larger than
// DATA_MAX travels as a grant instead of in `data`.
MessageBuf :: struct {
    from:     i64,
    tag_len:  i64,
    data_len: i64,
    grant:    i64, // NO_GRANT, or a grant this message hands to the receiver
    tag:      [TAG_MAX]u8,
    data:     [DATA_MAX]u8,
}

// --- Grants --------------------------------------------------------------------
//
// A grant is a block of memory that moves between processes. The sender allocates
// it, fills it, and sends it; at that moment it stops being mapped for the sender
// and becomes the receiver's to map. Exactly one process can reach a grant at any
// time, so the actor model's promise holds for bulk data too: there is no shared
// mutable state and so nothing to synchronize.
//
// This is what a buffer too big for DATA_MAX uses -- a window's pixels, say.

GRANT_MAX_SIZE :: GRANT_SLOT_SIZE

// What the kernel reports about a grant it just created or mapped.
GrantInfo :: struct {
    id:   i64,
    addr: i64,
    size: i64,
}
