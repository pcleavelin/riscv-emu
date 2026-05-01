package main

import "core:fmt"

import emu "./emu_core"

MAX_PHYS_MEM :: 1024 * 512 // 512KB

main :: proc() {
    e := emu.emu_make(MAX_PHYS_MEM)

    emu.emu_load_elf(&e, "examples/hello_world/out/hello_world.elf")
    emu.emu_set_break_point(&e, 0x0)
    emu.emu_run_interactive(&e)
}
