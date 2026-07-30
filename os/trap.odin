package kernel

// The supervisor trap handler and the user-mode boundary.
//
// This is where the actor API stops being a procedure call and becomes an ABI.
// A user process reaches the kernel only by ecall: it puts a syscall number in a7
// and arguments in a0/a1, the hardware traps into trap_entry, and the kernel reads
// them out of the saved TrapFrame. Nothing but registers crosses the boundary --
// anything larger is copied, in or out, by the two procedures at the bottom of
// this file.
//
// The syscall numbers live in sdk/abi, which apps import too, so the two sides of
// the boundary cannot drift apart. They are the kernel's own space: an ecall the
// kernel itself makes is a supervisor ecall and leaves for the host instead (see
// os/sbi.odin), so the two numberings never collide.

import "core:slice"

import emu "../bindings/odin"
import "../sdk/abi"

// Trap causes the kernel handles, as scause reports them.
CAUSE_ECALL_FROM_U :: 8

// The privilege a trap came from, as the saved sstatus records it: set means
// supervisor, clear means user.
SSTATUS_SPP :: u64(1) << 8

// A log line longer than this is truncated rather than trusted: the kernel copies
// it onto its own stack, and a process must not get to size that.
LOG_MAX :: 256

// The longest image name SYS_SPAWN accepts.
IMAGE_NAME_MAX :: 32

// The integer register file as trap_entry saves it, indexed by register number so
// the ABI registers are readable by name: a0 = x10, a1 = x11, a7 = x17.
//
// sepc and sstatus ride along because a syscall may block: other processes run in
// the meantime and their own traps overwrite both CSRs. This copy is the one that
// matters, so the handler adjusts sepc here rather than in the register.
TrapFrame :: struct {
    regs:    [32]u64,
    sepc:    u64,
    sstatus: u64,
}

REG_A0 :: 10
REG_A1 :: 11
REG_A7 :: 17

foreign import trap_asm "system:trap_asm"

@(default_calling_convention = "c")
foreign trap_asm {
    trap_entry :: proc() ---

    // Drop to user mode. Never returns -- control comes back only as a trap.
    user_enter :: proc(entry: u64, user_sp: u64) ---

    csr_read_scause :: proc() -> u64 ---
    csr_read_stval :: proc() -> u64 ---
    csr_write_stvec :: proc(value: u64) ---

    // Open and close the window in which the kernel may touch user memory.
    user_access_begin :: proc() ---
    user_access_end :: proc() ---
}

// Point stvec at the trap entry. Until this runs, any trap jumps to address 0.
trap_init :: proc() {
    csr_write_stvec(u64(uintptr(rawptr(trap_entry))))
}

// Every supervisor trap arrives here from trap_entry, with the interrupted
// registers saved in `frame`. Returning from this proc resumes whatever trapped.
@(export)
trap_handler :: proc "c" (frame: ^TrapFrame) {
    context = EMU_CONTEXT

    cause := csr_read_scause()

    if cause == CAUSE_ECALL_FROM_U {
        p := current_process
        assert(p != nil, "a syscall arrived with no process running")

        // sepc points at the ecall itself, so step past it or the process would
        // issue the same syscall forever. Done before the call, because a syscall
        // that blocks resumes here only after other processes have run.
        frame.sepc += 4
        frame.regs[REG_A0] = u64(
            user_syscall(p, frame.regs[REG_A7], frame.regs[REG_A0], frame.regs[REG_A1]),
        )
        return
    }

    // A fault in user code kills that process and nothing else, which is what
    // giving it an address space of its own buys. The same fault in the kernel is
    // fatal: there is no one else to blame and no one left to report to.
    from_user := (frame.sstatus & SSTATUS_SPP) == 0
    if from_user && current_process != nil {
        p := current_process
        kprint("kernel: process %d faulted, cause=%d sepc=%x stval=%x -- killing it\n",
            p.id, cause, frame.sepc, csr_read_stval())
        exit_current(p)
    }

    kprint("kernel: unhandled trap cause=%d sepc=%x stval=%x\n",
        cause, frame.sepc, csr_read_stval())
    emu.emu_shutdown()
}

// Service one syscall for `p`. The result is what the process finds in a0: zero or
// more for success, one of abi's negative errors for failure.
@(private)
user_syscall :: proc(p: ^Process, number, arg0, arg1: u64) -> i64 {
    switch number {
    case abi.SYS_EXIT:
        kprint("kernel: process %d exited with code %d\n", p.id, arg0)
        exit_current(p)

    case abi.SYS_YIELD:
        yield(p)
        return abi.OK

    case abi.SYS_SELF:
        return i64(p.id)

    case abi.SYS_LOG:
        buf: [LOG_MAX]u8
        length := min(arg1, u64(LOG_MAX))
        if !copy_from_user(p, buf[:length], arg0) do return abi.ERR_FAULT

        emu.print(string(buf[:length]))
        return i64(length)

    case abi.SYS_SEND:
        msg: abi.MessageBuf
        if !copy_from_user(p, slice.bytes_from_ptr(&msg, size_of(abi.MessageBuf)), arg1) {
            return abi.ERR_FAULT
        }

        // The lengths came from the process, so they are claims, not facts.
        if msg.tag_len < 0 || msg.tag_len > abi.TAG_MAX do return abi.ERR_FAULT
        if msg.data_len < 0 || msg.data_len > abi.DATA_MAX do return abi.ERR_FAULT

        to := ProcessId(i64(arg0))
        if int(to) < 0 || int(to) >= len(p.kernel.processes) do return abi.ERR_NO_PROC
        target := p.kernel.processes[int(to)]
        if target.state == .Dead do return abi.ERR_NO_PROC

        // Check the grant before queueing, so a send that cannot hand its memory
        // over fails without delivering a message that promises memory the
        // receiver will never get.
        grant := NO_GRANT
        if msg.grant != abi.NO_GRANT {
            grant = GrantId(msg.grant)
            if err := grant_transfer_check(grant, p, target); err != abi.OK do return err
        }

        tag := string(msg.tag[:msg.tag_len])
        if !deliver(p.kernel, p.id, to, tag, msg.data[:msg.data_len], grant) do return abi.ERR_FULL

        // Only now, with the message certain to arrive, does the memory change
        // hands. A refused send leaves the sender still holding it, still mapped
        // at the same address, so backing off and retrying is safe.
        if grant != NO_GRANT do grant_transfer(grant, p, target)
        return abi.OK

    case abi.SYS_RECV:
        // Blocks. The frame this returns into lives on p's own kernel stack, so it
        // sits untouched while other processes run.
        msg := recv(p)
        if !message_to_user(p, arg0, msg) do return abi.ERR_FAULT
        return abi.OK

    case abi.SYS_TRY_RECV:
        msg, ok := try_recv(p)
        if !ok do return abi.ERR_EMPTY
        if !message_to_user(p, arg0, msg) do return abi.ERR_FAULT
        return abi.OK

    case abi.SYS_GRANT_CREATE:
        info, err := grant_create(p, arg0)
        if err != abi.OK do return err
        if !copy_to_user(p, arg1, slice.bytes_from_ptr(&info, size_of(abi.GrantInfo))) {
            // The process cannot be told where its memory landed, so it could
            // never use or release it. Undo rather than leak.
            grant_drop(p, GrantId(info.id))
            return abi.ERR_FAULT
        }
        return abi.OK

    case abi.SYS_GRANT_MAP:
        info, err := grant_map(p, GrantId(i64(arg0)))
        if err != abi.OK do return err
        if !copy_to_user(p, arg1, slice.bytes_from_ptr(&info, size_of(abi.GrantInfo))) {
            return abi.ERR_FAULT
        }
        return abi.OK

    case abi.SYS_GRANT_DROP:
        return grant_drop(p, GrantId(i64(arg0)))

    case abi.SYS_SPAWN:
        name: [IMAGE_NAME_MAX]u8
        length := min(arg1, u64(IMAGE_NAME_MAX))
        if !copy_from_user(p, name[:length], arg0) do return abi.ERR_FAULT

        id, ok := spawn_user(p.kernel, string(name[:length]))
        if !ok do return abi.ERR_NO_PROC
        return i64(id)
    }

    kprint("kernel: process %d made an unknown syscall %d\n", p.id, number)
    return abi.ERR_BAD_CALL
}

// Hand a received message to the process as one MessageBuf. It is built here and
// copied out whole, so a process never holds a kernel pointer and never learns
// where any other process's memory is.
@(private)
message_to_user :: proc(p: ^Process, dest: u64, msg: Message) -> bool {
    buf: abi.MessageBuf
    buf.from = i64(msg.from)
    buf.tag_len = i64(len(msg.tag))
    buf.data_len = i64(len(msg.data))
    buf.grant = i64(msg.grant)
    copy(buf.tag[:], transmute([]u8)msg.tag)
    copy(buf.data[:], msg.data)

    return copy_to_user(p, dest, slice.bytes_from_ptr(&buf, size_of(abi.MessageBuf)))
}

// --- Crossing the boundary -----------------------------------------------------
//
// A pointer a process passes in is a claim about its own address space and nothing
// more. These two procedures are the only places the kernel dereferences one, and
// they refuse anything the process could not have reached by itself -- so a wrong
// or hostile pointer costs that process an ERR_FAULT instead of costing the kernel
// its integrity.

// Copy len(dst) bytes out of the process's memory. False means the range was not
// entirely readable by that process.
copy_from_user :: proc(p: ^Process, dst: []u8, src: u64) -> bool {
    if !user_range_ok(p, src, u64(len(dst)), PTE_R) do return false

    user_access_begin()
    copy(dst, ([^]u8)(uintptr(src))[:len(dst)])
    user_access_end()
    return true
}

// Copy bytes into the process's memory. False means the range was not entirely
// writable by that process.
copy_to_user :: proc(p: ^Process, dst: u64, src: []u8) -> bool {
    if !user_range_ok(p, dst, u64(len(src)), PTE_W) do return false

    user_access_begin()
    copy(([^]u8)(uintptr(dst))[:len(src)], src)
    user_access_end()
    return true
}

// Could `p` itself have reached this whole range, the way it asks to? Three things
// must hold: the range does not wrap, it lies entirely below KERNEL_BASE so a user
// pointer can never name kernel memory even by accident, and every page in it is
// mapped into p's own address space with PTE_U and the access it needs.
@(private)
user_range_ok :: proc(p: ^Process, vaddr: u64, size: u64, access: u64) -> bool {
    if size == 0 do return true
    if p.root == nil do return false

    end := vaddr + size
    if end < vaddr do return false
    if end > KERNEL_BASE do return false

    need := PTE_U | access
    for page := page_base(vaddr); page < end; page += PAGE_SIZE {
        pte, mapped := walk(p.root, page)
        if !mapped do return false
        if pte & need != need do return false
    }

    return true
}
