package main

import "base:intrinsics"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"

import emu "../../bindings/odin"

@(export)
plugin_start :: proc() {
    input := emu.readln()

    str := fmt.aprintf("You typed in: '%s'\n", input)
    emu.print(str)
}
