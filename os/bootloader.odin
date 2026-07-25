package bootloader

import "base:runtime"
import "core:mem"
import "core:slice"

import emu "../bindings/odin"

EMU_ARENA: mem.Arena
EMU_TEMP_ARENA: mem.Arena

EMU_ALLOCATOR: mem.Allocator
EMU_TEMP_ALLOCATOR: mem.Allocator

EMU_CONTEXT: runtime.Context

@(export)
_start :: proc() {
    data := slice.bytes_from_ptr(rawptr(uintptr(0x4000)), 1024 * 1024 * 512)
    mem.arena_init(&EMU_ARENA, data)

    EMU_ALLOCATOR = mem.arena_allocator(&EMU_ARENA)
    EMU_CONTEXT.allocator = EMU_ALLOCATOR

    temp_data, _ := runtime.mem_alloc_non_zeroed(128, allocator = EMU_ALLOCATOR)
    mem.arena_init(&EMU_TEMP_ARENA, temp_data)

    EMU_TEMP_ALLOCATOR = mem.arena_allocator(&EMU_TEMP_ARENA)
    EMU_CONTEXT.temp_allocator = EMU_TEMP_ALLOCATOR

    emu.print("Hello, Bootloader!\n")
    emu.emu_out_push_u64(0xBADBEEF)
}
