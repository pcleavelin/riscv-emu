package kernel

// Memory grants: a block of memory that moves from one process to another.
//
// A message carries at most DATA_MAX bytes inline, which is right for commands and
// wrong for a window's pixels. A grant is the other half: the sender allocates it,
// fills it, and hands it over, and at that moment it stops being mapped for the
// sender and becomes the receiver's.
//
// The memory moves rather than being shared, so exactly one process can reach a
// grant at any time. That keeps the actor model's promise for bulk data -- no
// shared mutable state, and so nothing to synchronize, no locks and no races. A
// sender that keeps using the buffer after sending it does not corrupt the
// receiver's view of it; it takes a page fault, which is the kind of mistake that
// reports itself.
//
// Frames are recorded per grant rather than being required to be contiguous,
// because the frame pool hands out single frames and would fragment against any
// contiguity requirement.

import "../sdk/abi"

GrantId :: distinct int

NO_GRANT :: GrantId(-1)

// A grant is capped at one slot, and the whole table is fixed, so grants cost a
// known amount of kernel memory and a process cannot exhaust the kernel by asking
// for more of them.
GRANT_MAX_PAGES :: abi.GRANT_MAX_SIZE / PAGE_SIZE
MAX_GRANTS :: 16

Grant :: struct {
    live:  bool,
    owner: ProcessId, // the one process entitled to map it
    size:  u64,       // as requested, which the frame count rounds up
    // Where the owner has it mapped, or NO_SLOT while it is in transit between
    // sending and mapping.
    slot: int,
    // The frames themselves. Physical addresses, so they mean the same thing in
    // whichever address space the grant lands in next.
    pages:      [GRANT_MAX_PAGES]u64,
    page_count: int,
}

NO_SLOT :: -1

// The grant table is kernel-wide and statically sized: an id is an index into it.
@(private)
grants: [MAX_GRANTS]Grant

// The address a grant occupies when mapped in slot `slot`.
@(private)
slot_addr :: proc(slot: int) -> u64 {
    return u64(abi.GRANT_BASE) + u64(slot)*u64(abi.GRANT_SLOT_SIZE)
}

// Find room in a process's grant region. A process may hold only GRANT_SLOTS
// grants mapped at once, which bounds how much of its address space grants can
// take and keeps the region's layout fixed.
@(private)
free_slot :: proc(p: ^Process) -> (slot: int, ok: bool) {
    for i in 0 ..< abi.GRANT_SLOTS {
        if p.grant_slots[i] == NO_GRANT do return i, true
    }
    return 0, false
}

// Is this grant one that `p` may act on? Ownership is the whole access rule: a
// process can name any id it likes, and only the owner gets anywhere.
@(private)
grant_owned_by :: proc(id: GrantId, p: ^Process) -> ^Grant {
    if int(id) < 0 || int(id) >= MAX_GRANTS do return nil

    g := &grants[int(id)]
    if !g.live || g.owner != p.id do return nil
    return g
}

// Map a grant's frames into a process at `slot` and record it there.
@(private)
grant_attach :: proc(id: GrantId, p: ^Process, slot: int) {
    g := &grants[int(id)]

    base := slot_addr(slot)
    for i in 0 ..< g.page_count {
        map_page(p.root, base + u64(i)*PAGE_SIZE, g.pages[i], PTE_R | PTE_W | PTE_U)
    }

    g.slot = slot
    p.grant_slots[slot] = id
}

// Take a grant's frames back out of the process that has it mapped. The frames
// survive: they are the grant, and it is only changing hands.
@(private)
grant_detach :: proc(id: GrantId, p: ^Process) {
    g := &grants[int(id)]
    if g.slot == NO_SLOT do return

    base := slot_addr(g.slot)
    for i in 0 ..< g.page_count {
        unmap_page(p.root, base + u64(i)*PAGE_SIZE)
    }

    p.grant_slots[g.slot] = NO_GRANT
    g.slot = NO_SLOT
}

// Create a grant of `size` bytes, owned by `p` and mapped into it. The frames come
// out of the pool already zeroed, so a process never sees what the last owner of
// that memory left behind.
grant_create :: proc(p: ^Process, size: u64) -> (info: abi.GrantInfo, err: i64) {
    if size == 0 || size > u64(abi.GRANT_MAX_SIZE) do return {}, abi.ERR_NO_SPACE

    slot := free_slot(p) or_else -1
    if slot < 0 do return {}, abi.ERR_NO_SPACE

    index := -1
    for i in 0 ..< MAX_GRANTS {
        if !grants[i].live {
            index = i
            break
        }
    }
    if index < 0 do return {}, abi.ERR_NO_SPACE

    pages := int(page_up(size) / PAGE_SIZE)

    g := &grants[index]
    g^ = Grant {
        live       = true,
        owner      = p.id,
        size       = size,
        slot       = NO_SLOT,
        page_count = pages,
    }
    for i in 0 ..< pages {
        g.pages[i] = frame_paddr(alloc_frame())
    }

    grant_attach(GrantId(index), p, slot)

    return abi.GrantInfo{id = i64(index), addr = i64(slot_addr(slot)), size = i64(size)}, abi.OK
}

// Would handing this grant from one process to the other work? Asked before the
// message is queued, so that a send either delivers the memory along with the
// message or changes nothing at all.
grant_transfer_check :: proc(id: GrantId, from: ^Process, to: ^Process) -> i64 {
    if grant_owned_by(id, from) == nil do return abi.ERR_NO_GRANT

    // A kernel process has no address space to map a grant into. The frames are
    // reachable by physical address but not contiguously, and nothing gives the
    // kernel a window to stitch them into, so grants stay between user processes.
    if to.root == nil do return abi.ERR_NO_PROC

    return abi.OK
}

// Hand a grant to another process, which is what makes a send of one a transfer.
// The sender loses the mapping here, before the receiver ever runs, so there is no
// window in which both can reach the memory.
//
// Call grant_transfer_check first: this reports failure but has already committed
// by the time it could.
grant_transfer :: proc(id: GrantId, from: ^Process, to: ^Process) -> i64 {
    g := grant_owned_by(id, from)
    if g == nil do return abi.ERR_NO_GRANT
    if to.root == nil do return abi.ERR_NO_PROC

    grant_detach(id, from)
    g.owner = to.id
    return abi.OK
}

// Map a grant the process owns but has not attached -- the receiving half of a
// transfer. The address comes back rather than going in: slots are the kernel's to
// hand out.
grant_map :: proc(p: ^Process, id: GrantId) -> (info: abi.GrantInfo, err: i64) {
    g := grant_owned_by(id, p)
    if g == nil do return {}, abi.ERR_NO_GRANT
    if g.slot != NO_SLOT do return {}, abi.ERR_NO_SPACE // already mapped

    slot := free_slot(p) or_else -1
    if slot < 0 do return {}, abi.ERR_NO_SPACE

    grant_attach(id, p, slot)
    return abi.GrantInfo{id = i64(id), addr = i64(slot_addr(slot)), size = i64(g.size)}, abi.OK
}

// Give a grant up for good: unmap it and return its frames to the pool.
grant_drop :: proc(p: ^Process, id: GrantId) -> i64 {
    g := grant_owned_by(id, p)
    if g == nil do return abi.ERR_NO_GRANT

    grant_detach(id, p)
    for i in 0 ..< g.page_count {
        free_frame(g.pages[i])
    }

    g^ = Grant{}
    return abi.OK
}

// Release every grant a dying process owns, including any still in transit to it.
//
// This must run before its address space is freed. A mapped grant's frames are
// reachable both through the page table and through the grant, and freeing the
// address space would collect them by the first route while the grant still names
// them by the second -- so they would go back to the pool twice.
grants_release :: proc(p: ^Process) {
    for i in 0 ..< MAX_GRANTS {
        g := &grants[i]
        if !g.live || g.owner != p.id do continue

        grant_detach(GrantId(i), p)
        for j in 0 ..< g.page_count {
            free_frame(g.pages[j])
        }
        g^ = Grant{}
    }
}
