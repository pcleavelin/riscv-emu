package kernel

// The supervisor trap handler and the user-mode boundary.
//
// This is where the actor API stops being a procedure call and becomes an ABI.
// A user process reaches the kernel only by ecall: it puts a syscall number in a7
// and arguments in a0/a1, the hardware traps into trap_entry, and the kernel reads
// them out of the saved TrapFrame. Nothing but registers crosses the boundary.

import emu "../bindings/odin"

// Trap causes the kernel handles, as scause reports them.
CAUSE_ECALL_FROM_U :: 8

// The user-facing syscall numbers. This space is the kernel's own: an ecall made
// by the kernel itself is a supervisor ecall and goes out to the host instead,
// which is the SBI role, so the two numberings never collide.
SYS_PRINT :: 1
SYS_EXIT :: 2

// The integer register file as trap_entry saves it, indexed by register number so
// the ABI registers are readable by name: a0 = x10, a1 = x11, a7 = x17.
TrapFrame :: struct {
    regs: [32]u64,
}

REG_A0 :: 10
REG_A1 :: 11
REG_A7 :: 17

foreign import trap_asm "system:trap_asm"

@(default_calling_convention = "c")
foreign trap_asm {
    trap_entry :: proc() ---
    user_enter :: proc(entry: u64, user_sp: u64, save: ^Context) ---
    ctx_restore :: proc(c: ^Context) ---

    // The user-side stub. Callable from kernel code too, but from S-mode the
    // ecall would go to the host rather than trapping here.
    do_syscall :: proc(number, arg0, arg1: u64) -> u64 ---

    csr_read_scause :: proc() -> u64 ---
    csr_read_sepc :: proc() -> u64 ---
    csr_write_sepc :: proc(value: u64) ---
    csr_read_stval :: proc() -> u64 ---
    csr_write_stvec :: proc(value: u64) ---

    // Open and close the window in which the kernel may touch user memory.
    user_access_begin :: proc() ---
    user_access_end :: proc() ---
}

// Where a user process returns to when it exits. Saved by user_enter.
@(private)
user_return: Context

// Point stvec at the trap entry. Until this runs, any trap jumps to address 0.
trap_init :: proc() {
    csr_write_stvec(u64(uintptr(rawptr(trap_entry))))
}

// Every supervisor trap arrives here from trap_entry, with the user's registers
// saved in `frame`. Returning from this proc resumes the user process; a syscall
// that must not resume it (exit) leaves through ctx_restore instead.
@(export)
trap_handler :: proc "c" (frame: ^TrapFrame) {
    context = EMU_CONTEXT

    cause := csr_read_scause()

    if cause == CAUSE_ECALL_FROM_U {
        result := user_syscall(frame.regs[REG_A7], frame.regs[REG_A0], frame.regs[REG_A1])
        frame.regs[REG_A0] = result

        // sepc points at the ecall itself, so step past it or the process would
        // issue the same syscall forever.
        csr_write_sepc(csr_read_sepc() + 4)
        return
    }

    kprint("kernel: unhandled trap cause=%d sepc=%x stval=%x\n",
        cause, csr_read_sepc(), csr_read_stval())
    emu.emu_shutdown()
}

@(private)
user_syscall :: proc(number, arg0, arg1: u64) -> u64 {
    switch number {
    case SYS_PRINT:
        // The pointer is a user address. Sharing one address space today makes
        // this safe by accident; once processes are mapped separately the kernel
        // will have to copy it in and validate it first.
        emu.print(string_from_user(arg0, arg1))
        return arg1

    case SYS_EXIT:
        kprint("kernel: user process exited with code %d\n", arg0)
        ctx_restore(&user_return) // does not return
    }

    kprint("kernel: unknown syscall %d\n", number)
    return 0
}

@(private)
string_from_user :: proc(ptr: u64, length: u64) -> string {
    bytes := ([^]u8)(uintptr(ptr))
    return string(bytes[:length])
}

// Drop to user mode at `entry` and run until the process exits, then come back
// here. The stack is the process's own; the kernel stack is stashed in sscratch
// for trap_entry to swap in.
run_user :: proc(entry: rawptr, user_stack: []u8) {
    stack_top := uintptr(raw_data(user_stack)) + uintptr(len(user_stack))
    user_enter(u64(uintptr(entry)), u64(stack_top &~ uintptr(15)), &user_return)
}
