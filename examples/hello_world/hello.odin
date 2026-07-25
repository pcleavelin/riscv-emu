package main

import "base:intrinsics"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"

import emu "../../bindings/odin"

main :: proc "contextless" () {
    context = emu.EMU_CONTEXT

    b :u64= 0xfDEADDAD1BADBEEF

    hello_str := fmt.aprintf("Hello, World! 0x%x\n", b)
    emu.print(hello_str)
}
