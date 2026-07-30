package kernel

// Services the kernel asks the host for, over the supervisor ecall.
//
// Application images are one of them. The kernel has no filesystem, and an app
// is a separately linked ELF rather than something built into the kernel image,
// so the bytes have to come from outside: the kernel asks for a size, stages a
// buffer, and asks for the bytes.

import "base:runtime"

SBI_IMAGE_SIZE :: 0x20 // (name_ptr, name_len) -> size in bytes, 0 if unknown
SBI_IMAGE_READ :: 0x21 // (name_ptr, name_len, dest) -> bytes written

SBI_TIME :: 0x30      // -> ticks since the machine started
SBI_SET_TIMER :: 0x31 // (deadline) -> arms it, and clears the old one

foreign import sbi_asm "system:sbi_asm"

@(default_calling_convention = "c")
foreign sbi_asm {
    sbi_call :: proc(number, arg0, arg1, arg2: u64) -> u64 ---
}

// The machine's clock, counted in instructions retired rather than seconds. Only
// the difference between two readings means anything.
sbi_time :: proc() -> u64 {
    return sbi_call(SBI_TIME, 0, 0, 0)
}

// Ask to be interrupted once the clock reaches `deadline`, and acknowledge any
// timer interrupt already pending.
sbi_set_timer :: proc(deadline: u64) {
    sbi_call(SBI_SET_TIMER, deadline, 0, 0)
}

// The size of the image named `name`, or zero when the host has no such image.
// A name is a bare image name -- "counter", not a path.
image_size :: proc(name: string) -> u64 {
    return sbi_call(SBI_IMAGE_SIZE, u64(uintptr(raw_data(name))), u64(len(name)), 0)
}

// Read a whole image into `dest` and report how many bytes arrived. Zero means
// either that the host has no such image or that `dest` is too short for it.
image_read :: proc(name: string, dest: []u8) -> u64 {
    size := image_size(name)
    if size == 0 || u64(len(dest)) < size do return 0

    return sbi_call(
        SBI_IMAGE_READ,
        u64(uintptr(raw_data(name))),
        u64(len(name)),
        u64(uintptr(raw_data(dest))),
    )
}

// Fetch an image into a fresh kernel buffer. The caller owns the buffer and can
// discard it once the loader has copied the segments out of it.
image_load :: proc(name: string, allocator := context.allocator) -> (image: []u8, ok: bool) {
    size := image_size(name)
    if size == 0 do return nil, false

    // Not zeroed first: the read overwrites every byte of it, and clearing a
    // third of a megabyte through the runtime's memset costs more than the read
    // that follows it.
    buf, err := runtime.mem_alloc_non_zeroed(int(size), allocator = allocator)
    if err != nil do return nil, false

    if image_read(name, buf) != size do return nil, false

    return buf, true
}
