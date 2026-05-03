package main

import "base:intrinsics"
import "core:fmt"
import "core:mem"
import "core:slice"

foreign import emu_stdlib "system:emu_stdlib"

@(default_calling_convention = "c")
foreign emu_stdlib {
    emu_syscall :: proc() ---
    emu_println :: proc(buf: ^u8, len: int) ---
}

println :: proc(str: string) {
    new_line :string: "\n"
    emu_println(transmute(^u8)raw_data(str), len(str))
    emu_println(transmute(^u8)raw_data(new_line), len(new_line))
}

@(export)
_start :: proc() {
    fake_data := slice.bytes_from_ptr(rawptr(uintptr(0x4000)), 1024 * 4)
    buddy: mem.Arena
    mem.arena_init(&buddy, fake_data)

    allocator := mem.arena_allocator(&buddy)

    context.allocator = allocator
    context.temp_allocator =  allocator

    b := 0x2DEADDAD1BADBEEF

    println("Look at this cool number!")
    println("Why does it print out the file path of fmt.odin?")

    hello_str := fmt.aprintf("Hello, World! 0x%x\n", b)
    println(hello_str)

}
