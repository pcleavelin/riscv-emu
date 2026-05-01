package main

import "base:intrinsics"

@(export)
_start :: proc() {
    intrinsics.syscall(0xA, 0x1337, 0x2332)
    b := 0x2DEADDAD1BADBEEF
}
