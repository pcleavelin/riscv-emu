package main

import "base:intrinsics"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"

foreign import emu_stdlib "system:emu_stdlib"

@(default_calling_convention = "c")
foreign emu_stdlib {
    emu_syscall :: proc() ---
    emu_out_call_host_fn :: proc(buf: ^u8, len: int) ---

    emu_out_push_u32 :: proc(val: u32) ---
    emu_out_push_ptr :: proc(val: u64) ---

    emu_out_pop_u32 :: proc() -> u32 ---
    emu_out_pop_ptr :: proc() -> u64 ---
}

EmuString8 :: struct {
    data: ^u8,
    len: u32
}

out_pop_string :: proc() -> string {
    str_addr := emu_out_pop_ptr()
    str_len := emu_out_pop_u32()

    return strings.string_from_ptr(transmute(^u8)uintptr(str_addr), int(str_len))
}

println :: proc(str: string) {
    emu_out_push_u32(u32(len(str)))
    emu_out_push_ptr(u64(uintptr(transmute(^u8)raw_data(str))))

    func_str := "core::println"
    emu_out_call_host_fn(transmute(^u8)raw_data(func_str), len(func_str))

    func_str2 := "is_this_a_function?"
    emu_out_call_host_fn(transmute(^u8)raw_data(func_str2), len(func_str2))
}

@(export)
_start :: proc() {
    fake_data := slice.bytes_from_ptr(rawptr(uintptr(0x4000)), 1024 * 4)
    buddy: mem.Arena
    mem.arena_init(&buddy, fake_data)

    allocator := mem.arena_allocator(&buddy)

    context.allocator = allocator
    context.temp_allocator =  allocator

    b :u64= 0xfDEADDAD1BADBEEF

    hello_str := fmt.aprintf("Hello, World! 0x%x\n", b)
    println(hello_str)
}
