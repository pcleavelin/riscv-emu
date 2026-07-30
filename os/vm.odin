package kernel

// Virtual memory: page table construction and the switch into paged mode.
//
// Sv39 splits a 39-bit virtual address into three 9-bit table indices and a
// 12-bit offset. A walk starts at the root table named by satp and descends
// until it finds a leaf. A leaf above the bottom level is a superpage covering
// 2MB or 1GB, which is what makes the kernel's identity map a handful of entries
// rather than a million.

import "core:mem"
import "core:slice"

// --- Kernel memory map ---------------------------------------------------------
//
// The kernel lives entirely inside one 1GB region and identity maps just that,
// which leaves the whole low half of every address space to user processes. The
// first two megabytes are reserved by the link scripts:
//
//   0x8000_0000  kernel image    512K, reserved by os/kernel.ld
//   0x8008_0000  stdlib runtime  512K, reserved by stdlib/link.ld
//   0x8010_0000  kernel heap     256MB, an arena, grows up
//   0x9010_0000  frame pool      256MB, 4KB frames, handed out and taken back
//   0xC000_0000  kernel stack    grows down, set by the emulator's boot vector

KERNEL_BASE :: u64(0x8000_0000)
KERNEL_HEAP_BASE :: uintptr(0x8010_0000)
KERNEL_HEAP_SIZE :: 256 * 1024 * 1024

// Frames live in a region of their own, immediately past the heap, because they
// must come back: the page tables and pages of a dead process are the bulk of what
// it owned, and the heap is an arena that can only be freed all at once.
FRAME_POOL_BASE :: u64(KERNEL_HEAP_BASE) + KERNEL_HEAP_SIZE
FRAME_POOL_SIZE :: 256 * 1024 * 1024
FRAME_POOL_END :: FRAME_POOL_BASE + FRAME_POOL_SIZE

PAGE_SIZE :: 4096
PTE_PER_PAGE :: 512

// Page table entry flags.
PTE_V :: u64(1) << 0 // valid
PTE_R :: u64(1) << 1 // readable
PTE_W :: u64(1) << 2 // writable
PTE_X :: u64(1) << 3 // executable
PTE_U :: u64(1) << 4 // reachable from user mode
PTE_A :: u64(1) << 6 // accessed
PTE_D :: u64(1) << 7 // dirty

SATP_MODE_SV39 :: u64(8)

// A page table is one 4KB frame holding 512 entries.
PageTable :: [PTE_PER_PAGE]u64

foreign import vm_asm "system:vm_asm"

@(default_calling_convention = "c")
foreign vm_asm {
    csr_write_satp :: proc(value: u64) ---
    csr_read_satp :: proc() -> u64 ---
}

// The first address of the page that holds `addr`, and the first address of the
// page after it.
page_base :: proc(addr: u64) -> u64 {
    return addr &~ u64(PAGE_SIZE - 1)
}

page_up :: proc(addr: u64) -> u64 {
    return page_base(addr + PAGE_SIZE - 1)
}

// --- The frame allocator -------------------------------------------------------
//
// Every frame is the same size, so there is nothing to search: a free frame is
// simply on a list. The list is threaded through the free frames themselves, each
// holding the address of the next in its first eight bytes, so tracking them costs
// no memory of its own and freeing one is a couple of stores.
//
// Frames beyond the ones that have already been freed come off a bump pointer.
// That way the pool costs only what has been touched, which matters because the
// machine's physical memory is far smaller than the region reserved here.
//
// Addresses here are physical. Using them as Odin pointers is only correct while
// the kernel is identity mapped, which is the same assumption map_page and walk
// make.

@(private) frame_free_list: u64 // first free frame, or zero when the list is empty
@(private) frame_next_new: u64  // the next frame never yet handed out

frames_in_use: int
frames_peak: int

// Arm the bump pointer. Must run before anything allocates, which means before
// paging_init, since a page table is a frame.
frame_pool_init :: proc() {
    frame_free_list = 0
    frame_next_new = FRAME_POOL_BASE
    frames_in_use = 0
    frames_peak = 0
}

// Check that a freed frame comes back out again. The counters alone would not
// notice a broken free list -- they would keep tallying while every allocation
// quietly came off the bump pointer and the pool grew forever.
//
// The frame left on the list is not waste: the next allocation takes it.
frame_pool_check :: proc() {
    first := frame_paddr(alloc_frame())
    free_frame(first)

    again := frame_paddr(alloc_frame())
    assert(again == first, "a freed frame was not handed back out")
    free_frame(again)
}

// Take one zeroed, page-aligned frame. Alignment is not optional: satp and the
// page table entries store a frame number, so the low 12 bits must be zero -- and
// the pool being page-aligned is what guarantees it.
//
// Callers rely on a fresh frame being zero: it is what makes a page table valid to
// walk and what makes an application's bss cost nothing to clear.
alloc_frame :: proc() -> []u8 {
    paddr := frame_free_list

    if paddr != 0 {
        frame_free_list = (^u64)(uintptr(paddr))^
    } else {
        assert(frame_next_new < FRAME_POOL_END, "out of frames")
        paddr = frame_next_new
        frame_next_new += PAGE_SIZE
    }

    frames_in_use += 1
    if frames_in_use > frames_peak do frames_peak = frames_in_use

    frame := slice.bytes_from_ptr(rawptr(uintptr(paddr)), PAGE_SIZE)
    mem.zero(raw_data(frame), PAGE_SIZE)
    return frame
}

// Report the pool, and check that it adds up: every frame ever taken from the bump
// pointer is either in use or on the free list. A frame freed twice would sit on
// the list twice and make the totals disagree, or, if the two frees formed a cycle,
// run the walk past the number of frames that exist.
frame_pool_report :: proc() {
    taken := int((frame_next_new - FRAME_POOL_BASE) / PAGE_SIZE)

    free_count := 0
    for frame := frame_free_list; frame != 0; frame = (^u64)(uintptr(frame))^ {
        free_count += 1
        assert(free_count <= taken, "the frame free list has a cycle")
    }

    kprint("kernel: frames %d in use, %d free, %d at peak\n",
        frames_in_use, free_count, frames_peak)
    assert(frames_in_use + free_count == taken, "frames have gone missing from the pool")
}

// Give a frame back. It goes on the head of the free list, so the next allocation
// reuses the most recently freed frame and the pool stays as compact as it can.
free_frame :: proc(paddr: u64) {
    assert(paddr >= FRAME_POOL_BASE && paddr < FRAME_POOL_END, "that address is not a frame")
    assert(paddr & (PAGE_SIZE - 1) == 0, "that address is not the start of a frame")

    (^u64)(uintptr(paddr))^ = frame_free_list
    frame_free_list = paddr
    frames_in_use -= 1
}

// The physical address of a frame. The kernel is identity mapped, so a frame's
// own address is also what a page table entry must name.
frame_paddr :: proc(frame: []u8) -> u64 {
    return u64(uintptr(raw_data(frame)))
}

// A page table is one frame read as 512 entries.
alloc_page_table :: proc() -> ^PageTable {
    return cast(^PageTable)raw_data(alloc_frame())
}

// Build a leaf entry pointing at a physical address.
@(private)
leaf_pte :: proc(paddr: u64, flags: u64) -> u64 {
    return ((paddr >> 12) << 10) | flags | PTE_V | PTE_A | PTE_D
}

// Map one 1GB superpage: a leaf at the top level, so the bottom 30 bits of the
// address come straight from the virtual address.
map_gigapage :: proc(root: ^PageTable, vaddr: u64, paddr: u64, flags: u64) {
    index := (vaddr >> 30) & 0x1FF
    root[index] = leaf_pte(paddr, flags)
}

// Map one 4KB page, creating the intermediate tables the walk needs. Only the
// leaf carries permissions -- a non-leaf entry must have R, W and X all clear or
// the walker would read it as a superpage.
//
// Table pointers are physical addresses. Dereferencing them as Odin pointers is
// only correct while the kernel is identity mapped.
map_page :: proc(root: ^PageTable, vaddr: u64, paddr: u64, flags: u64) {
    table := root

    for level := 2; level > 0; level -= 1 {
        index := (vaddr >> uint(12 + 9*level)) & 0x1FF
        pte := table[index]

        if (pte & PTE_V) == 0 {
            next := alloc_page_table()
            table[index] = ((u64(uintptr(next)) >> 12) << 10) | PTE_V
            table = next
            continue
        }

        assert(pte & (PTE_R | PTE_W | PTE_X) == 0, "cannot map inside an existing superpage")
        table = cast(^PageTable)uintptr((pte >> 10) << 12)
    }

    table[(vaddr >> 12) & 0x1FF] = leaf_pte(paddr, flags)
}

// Remove the mapping for `vaddr` and report the frame it named. The frame itself
// is untouched, because the caller may be moving it to another address space
// rather than giving it back.
//
// The tables that led to it stay: a process that unmaps one page has usually not
// finished with that region, and free_address_space collects them in the end.
unmap_page :: proc(root: ^PageTable, vaddr: u64) -> (paddr: u64, ok: bool) {
    table := root

    for level := 2; level > 0; level -= 1 {
        entry := table[(vaddr >> uint(12 + 9*level)) & 0x1FF]
        if (entry & PTE_V) == 0 do return 0, false
        if entry & (PTE_R | PTE_W | PTE_X) != 0 do return 0, false // a superpage

        table = cast(^PageTable)uintptr((entry >> 10) << 12)
    }

    index := (vaddr >> 12) & 0x1FF
    entry := table[index]
    if (entry & PTE_V) == 0 do return 0, false

    table[index] = 0
    return (entry >> 10) << 12, true
}

// Find the leaf entry that maps `vaddr`, or report that nothing does. A leaf can
// turn up above the bottom level as a superpage, which is why this descends
// looking for permission bits rather than simply indexing three times.
//
// Table pointers are physical addresses, so this is only correct while the kernel
// is identity mapped.
walk :: proc(root: ^PageTable, vaddr: u64) -> (pte: u64, ok: bool) {
    table := root

    for level := 2; level >= 0; level -= 1 {
        entry := table[(vaddr >> uint(12 + 9*level)) & 0x1FF]
        if (entry & PTE_V) == 0 do return 0, false

        // Permission bits are what distinguishes a leaf from a table pointer.
        if entry & (PTE_R | PTE_W | PTE_X) != 0 do return entry, true

        table = cast(^PageTable)uintptr((entry >> 10) << 12)
    }

    return 0, false
}

// Turn on paging with an identity map: every virtual address is its own physical
// address. Nothing the kernel does changes meaning, which is exactly the point --
// if the system still runs afterwards, the walker is correct. Distinct per-process
// maps build on top of this.
paging_init :: proc() -> ^PageTable {
    root := alloc_page_table()

    // A single 1GB page covers the image, the runtime, the heap and the stack.
    // No U flag, so nothing here is reachable from user mode -- and everything
    // below KERNEL_BASE is left unmapped, free for processes to occupy.
    map_gigapage(root, KERNEL_BASE, KERNEL_BASE, PTE_R | PTE_W | PTE_X)

    satp_write_root(root)
    return root
}

// A fresh address space that starts out sharing the kernel's mappings. Every
// address space must contain the kernel, because a trap does not change satp:
// the handler runs on whatever page table the interrupted code was using. The
// kernel entries carry no U flag, so user code still cannot reach them.
create_address_space :: proc() -> ^PageTable {
    space := alloc_page_table()
    space^ = kernel_root^
    return space
}

// Give back everything an address space owns: the frames its pages point at, and
// the tables that map them.
//
// Only the part below KERNEL_BASE is the process's. The entries above it were
// copied from kernel_root by create_address_space and are shared by every address
// space, so following them would free the kernel out from under itself.
//
// The caller must not be running on this address space any more.
free_address_space :: proc(root: ^PageTable) {
    for i in 0 ..< int(KERNEL_BASE >> 30) {
        if (root[i] & PTE_V) == 0 do continue
        free_subtree(root[i], 2)
        root[i] = 0
    }

    free_frame(u64(uintptr(root)))
}

// Free one entry and everything below it: a leaf owns a frame, anything else owns
// a table whose own entries have to go first. `level` is the level the entry itself
// lives at, so it counts down to zero at the bottom.
@(private)
free_subtree :: proc(entry: u64, level: int) {
    paddr := (entry >> 10) << 12

    if entry & (PTE_R | PTE_W | PTE_X) != 0 {
        // The loader maps user space in 4KB pages only, so a leaf down here owns
        // exactly one frame. A superpage would own 512 or more of them at once.
        assert(level == 0, "a superpage cannot be freed as a single frame")
        free_frame(paddr)
        return
    }

    assert(level > 0, "a bottom-level entry must be a leaf")

    table := cast(^PageTable)uintptr(paddr)
    for i in 0 ..< PTE_PER_PAGE {
        if (table[i] & PTE_V) != 0 do free_subtree(table[i], level - 1)
    }

    free_frame(paddr)
}

// Point satp at a root table and switch to Sv39.
satp_write_root :: proc(root: ^PageTable) {
    root_pa := u64(uintptr(root))
    csr_write_satp((SATP_MODE_SV39 << 60) | (root_pa >> 12))
}
