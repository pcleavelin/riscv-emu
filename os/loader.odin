package kernel

// The ELF loader: turns an application image into an address space that can run.
//
// An app is a separately linked ELF rather than something built into the kernel
// image, because the supervisor may never fetch instructions from a page marked
// for user access -- kernel and user code cannot share a page. So the kernel
// reads the image from the host, copies each loadable segment into frames of its
// own, and maps those frames at the addresses the app was linked for, along with
// the stack and heap its runtime expects to find.

import "../sdk/abi"

// ELF64 header field offsets. The machine is little-endian, which is the only
// encoding this reads.
EI_MAG :: 0x00
EI_CLASS :: 0x04
E_TYPE :: 0x10
E_MACHINE :: 0x12
E_ENTRY :: 0x18
E_PHOFF :: 0x20
E_PHENTSIZE :: 0x36
E_PHNUM :: 0x38
ELF_HEADER_SIZE :: 0x40

// Program header field offsets, from the start of one program header.
P_TYPE :: 0x00
P_FLAGS :: 0x04
P_OFFSET :: 0x08
P_VADDR :: 0x10
P_FILESZ :: 0x20
P_MEMSZ :: 0x28

// The 7f E L F magic, as a little-endian word.
ELF_MAGIC :: u64(0x464C_457F)

ELFCLASS64 :: 2
ET_EXEC :: 2
EM_RISCV :: 243

PT_LOAD :: 1

// Segment permissions, as p_flags reports them.
PF_X :: u64(1)
PF_W :: u64(2)
PF_R :: u64(4)

// An image loaded and ready to run: the address space holding it, and where in
// that space to start executing.
LoadedImage :: struct {
    root:  ^PageTable,
    entry: u64,
}

// Load the application image named `name` into an address space of its own. The
// space contains the kernel as well, because a trap does not change satp, but
// only the app's own pages carry PTE_U.
load_image :: proc(name: string) -> (img: LoadedImage, ok: bool) {
    // The staging buffer is temporary, so the arena is rolled back to where it
    // stood once the segments have been copied out of it. Everything the loader
    // keeps -- frames and page tables -- comes from the frame pool instead, so
    // nothing that must survive lives inside the region discarded here.
    mark := EMU_ARENA.offset
    defer EMU_ARENA.offset = mark

    image := image_load(name) or_return
    if !elf_is_loadable(image, name) do return {}, false

    space := create_address_space()

    phoff := read_le(image, E_PHOFF, 8)
    phentsize := read_le(image, E_PHENTSIZE, 2)
    phnum := read_le(image, E_PHNUM, 2)

    // Each page gets its own frame and nothing merges two segments into one, so
    // the segments must arrive in ascending order and never share a page. The app
    // link script aligns every section to a page boundary, so they do not.
    mapped_to := u64(0)

    for i in 0 ..< phnum {
        ph := phoff + i*phentsize
        if read_le(image, ph + P_TYPE, 4) != PT_LOAD do continue

        vaddr := read_le(image, ph + P_VADDR, 8)
        memsz := read_le(image, ph + P_MEMSZ, 8)

        assert(page_base(vaddr) >= mapped_to, "PT_LOAD segments share a page")
        map_segment(space, image, ph)
        mapped_to = page_up(vaddr + memsz)
    }

    map_anonymous(space, abi.USER_HEAP_BASE, abi.USER_HEAP_SIZE)
    map_anonymous(space, abi.USER_STACK_TOP - abi.USER_STACK_SIZE, abi.USER_STACK_SIZE)

    return LoadedImage{root = space, entry = read_le(image, E_ENTRY, 8)}, true
}

// Copy one loadable segment into fresh frames and map them where the app expects
// them. Bytes between p_filesz and p_memsz are bss and stay zero, which a fresh
// frame already is.
@(private)
map_segment :: proc(space: ^PageTable, image: []u8, ph: u64) {
    offset := read_le(image, ph + P_OFFSET, 8)
    vaddr := read_le(image, ph + P_VADDR, 8)
    filesz := read_le(image, ph + P_FILESZ, 8)
    memsz := read_le(image, ph + P_MEMSZ, 8)
    flags := segment_flags(read_le(image, ph + P_FLAGS, 4))

    for page := page_base(vaddr); page < vaddr + memsz; page += PAGE_SIZE {
        frame := alloc_frame()
        map_page(space, page, frame_paddr(frame), flags)

        // The part of this page that comes from the file. Writing through the
        // frame's own address works because the kernel is identity mapped: it is
        // the same memory the process will read at `page`, reached without
        // switching address spaces or opening the user window.
        from := max(page, vaddr)
        to := min(page + PAGE_SIZE, vaddr + filesz)
        if from < to {
            copy(frame[from - page:], image[offset + from - vaddr:offset + to - vaddr])
        }
    }
}

// Map a zeroed, writable region that is not in the image at all. The SDK's _start
// assumes the kernel provided both a heap and a stack.
@(private)
map_anonymous :: proc(space: ^PageTable, base: u64, size: u64) {
    for offset := u64(0); offset < size; offset += PAGE_SIZE {
        map_page(space, base + offset, frame_paddr(alloc_frame()), PTE_R | PTE_W | PTE_U)
    }
}

// Page permissions for a segment. PTE_U is unconditional: everything the loader
// maps belongs to the process.
@(private)
segment_flags :: proc(p_flags: u64) -> u64 {
    flags := PTE_U
    if p_flags & PF_R != 0 do flags |= PTE_R
    if p_flags & PF_W != 0 do flags |= PTE_W
    if p_flags & PF_X != 0 do flags |= PTE_X
    return flags
}

// Reject an image the loader cannot honestly run, and say which way it is wrong.
// ET_EXEC matters: nothing here relocates, so the image must already be linked
// for the addresses it asks for.
@(private)
elf_is_loadable :: proc(image: []u8, name: string) -> bool {
    if u64(len(image)) < ELF_HEADER_SIZE {
        kprint("loader: '%s' is too short to hold an ELF header\n", name)
        return false
    }
    if read_le(image, EI_MAG, 4) != ELF_MAGIC {
        kprint("loader: '%s' is not an ELF\n", name)
        return false
    }
    if image[EI_CLASS] != ELFCLASS64 || read_le(image, E_MACHINE, 2) != EM_RISCV {
        kprint("loader: '%s' is not a 64-bit RISC-V image\n", name)
        return false
    }
    if read_le(image, E_TYPE, 2) != ET_EXEC {
        kprint("loader: '%s' is not a fixed-address executable\n", name)
        return false
    }
    return true
}

// Read a little-endian integer field out of the staging buffer. The buffer has no
// alignment guarantee, so a field is assembled a byte at a time.
@(private)
read_le :: proc(buf: []u8, offset: u64, size: u64) -> u64 {
    value: u64
    for i in 0 ..< size {
        value |= u64(buf[offset + i]) << (8 * uint(i))
    }
    return value
}
