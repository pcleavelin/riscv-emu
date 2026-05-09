package main

import "core:fmt"

import emu "./emu_core"

MAX_PHYS_MEM :: 1024 * 512 // 512KB

run_program :: proc(e: ^emu.Emu64, path: string) -> (ok: bool) {
    lib_addr := emu.emu_load_elf(e, "bin/stdlib.elf") or_return
    user_addr := emu.emu_load_elf(e, path) or_return

    emu.emu_set_break_point(e, 0x0)

    main_proc: u64
    if f, ok := e.functions["plugin_start"]; ok {
        main_proc = f.addr
    } else {
        fmt.eprintln("couldn't find main function")
    }

    emu.emu_run_function(e, "_start", emu.EmuArgU64(main_proc))

    return true
}

main :: proc() {
    e := emu.emu_make(MAX_PHYS_MEM)

    ok := run_program(&e, "examples/host_to_guest/out/prog.elf")
    if !ok do return
}
