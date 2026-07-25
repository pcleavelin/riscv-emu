package main

import "core:fmt"

import emu "./emu_core"

MAX_PHYS_MEM :: 1024 * 512 // 512KB

// Load a bootloader image and run the machine from its ELF entry point until it
// halts. The shared guest runtime (stdlib.elf: memset/memcpy and the syscall
// wrappers) loads first at its linked addresses; the boot image references it.
// This is the whole VM lifecycle: one entry, run to shutdown.
run_bootloader :: proc(e: ^emu.Emu64, boot_path: string) -> (ok: bool) {
    emu.emu_load_elf(e, "bin/stdlib.elf") or_return
    entry := emu.emu_load_elf(e, boot_path) or_return

    emu.emu_boot(e, entry)
    reason := emu.emu_run(e)
    fmt.println("VM halted:", reason)

    return true
}

main :: proc() {
    e := emu.emu_make(MAX_PHYS_MEM)

    if !run_bootloader(&e, "os/bin/bootloader.elf") {
        fmt.eprintln("failed to load bootloader image")
    }
}
