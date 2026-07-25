package kernel

// Virtual memory: page table construction and the switch into paged mode.
//
// Sv39 splits a 39-bit virtual address into three 9-bit table indices and a
// 12-bit offset. A walk starts at the root table named by satp and descends
// until it finds a leaf. A leaf above the bottom level is a superpage covering
// 2MB or 1GB, which is what makes the kernel's identity map a handful of entries
// rather than a million.

import "core:mem"

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

// Allocate a zeroed, page-aligned table. Alignment is not optional: satp and the
// non-leaf entries store a frame number, so the low 12 bits must be zero.
alloc_page_table :: proc() -> ^PageTable {
    ptr, err := mem.alloc(size_of(PageTable), PAGE_SIZE, EMU_ALLOCATOR)
    assert(err == nil, "out of memory allocating a page table")
    assert(uintptr(ptr) & (PAGE_SIZE - 1) == 0, "page table is not page-aligned")
    return cast(^PageTable)ptr
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

// Turn on paging with an identity map: every virtual address is its own physical
// address. Nothing the kernel does changes meaning, which is exactly the point --
// if the system still runs afterwards, the walker is correct. Distinct per-process
// maps build on top of this.
paging_init :: proc() -> ^PageTable {
    root := alloc_page_table()

    // Four 1GB pages cover everything in use: the guest arena low down and the
    // kernel image at 0x8000_0000. Supervisor-only, since no U flag is set.
    for i in 0 ..< u64(4) {
        base := i << 30
        map_gigapage(root, base, base, PTE_R | PTE_W | PTE_X)
    }

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

// Point satp at a root table and switch to Sv39.
satp_write_root :: proc(root: ^PageTable) {
    root_pa := u64(uintptr(root))
    csr_write_satp((SATP_MODE_SV39 << 60) | (root_pa >> 12))
}
