package main

// The terminal front end: the machine, showing its display as half-block
// characters. Needs no window and no library, so it runs anywhere a shell does,
// including over ssh. See src/gui for the same machine in a real window.

import "core:fmt"
import "core:os"

import emu "./emu_core"
import "./term"

MAX_PHYS_MEM :: 1024 * 1024 * 16 // 16MB: backs the lazily-created guest pages

// Load a bootloader image and run the machine from its ELF entry point until it
// halts. The shared guest runtime (stdlib.elf: memset/memcpy and the syscall
// wrappers) loads first at its linked addresses; the boot image references it.
// This is the whole VM lifecycle: one entry, run to shutdown.
run_bootloader :: proc(e: ^emu.Emu64, boot_path: string) -> (ok: bool) {
    emu.emu_load_elf(e, "bin/stdlib.elf") or_return
    entry := emu.emu_load_elf(e, boot_path) or_return

    emu.emu_boot(e, entry)
    reason := emu.emu_run(e)
    fmt.eprintln("VM halted:", reason)

    return true
}

main :: proc() {
    e := emu.emu_make(MAX_PHYS_MEM)

    // The guest's log goes to stderr and its display to stdout, so redirecting one
    // leaves the other alone -- which is what makes the picture readable at all.
    graphical := len(os.args) < 2 || os.args[1] != "--quiet"
    if graphical {
        e.display.show = term.show
        term.start()
    }

    if !run_bootloader(&e, "os/bin/kernel.elf") {
        fmt.eprintln("failed to load bootloader image")
    }

    if graphical do term.stop()
}
