package main

import "core:fmt"

import emu "./emu_core"

MAX_PHYS_MEM :: 1024 * 512 // 512KB

run_program :: proc(e: ^emu.Emu64, path: string) -> (ok: bool) {
    lib_addr := emu.emu_load_elf(e, "bin/stdlib.elf") or_return
    user_addr := emu.emu_load_elf(e, path) or_return

    emu.emu_set_break_point(e, 0x0)
    emu.emu_run_addr(e, lib_addr)
    emu.emu_run_addr(e, user_addr)

    return true
}

main :: proc() {
    e := emu.emu_make(MAX_PHYS_MEM)

    ok := run_program(&e, "examples/hello_world/out/hello_world.elf")
    if !ok do return
}
