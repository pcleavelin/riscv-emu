package kernel

// Example app: a user-mode process.
//
// Unlike the counter and ticker, this does not run in the kernel. It executes in
// U-mode and cannot touch kernel memory, call kernel procedures, or reach the
// host -- an ecall from here traps into the kernel instead. Everything it does
// goes through the syscall stub.

@(private)
user_print :: proc "contextless" (msg: string) {
    do_syscall(SYS_PRINT, u64(uintptr(raw_data(msg))), u64(len(msg)))
}

hello_user :: proc "c" () {
    user_print("hello from user mode\n")
    user_print("...still in user mode\n")

    do_syscall(SYS_EXIT, 0, 0)
}
