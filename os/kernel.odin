package kernel

// The OS kernel image, entered from the emulator's boot vector. _start brings up
// the guest allocator, then hands control to the scheduler. The initial processes
// are registered by boot() (os/boot.odin); once user apps load from their own
// ELFs at runtime, that hook becomes a real launcher.

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:slice"

import emu "../bindings/odin"

EMU_ARENA: mem.Arena
EMU_TEMP_ARENA: mem.Arena

EMU_ALLOCATOR: mem.Allocator
EMU_TEMP_ALLOCATOR: mem.Allocator

EMU_CONTEXT: runtime.Context

@(export)
_start :: proc() {
    data := slice.bytes_from_ptr(rawptr(uintptr(0x4000)), 1024 * 1024 * 512)
    mem.arena_init(&EMU_ARENA, data)

    EMU_ALLOCATOR = mem.arena_allocator(&EMU_ARENA)
    EMU_CONTEXT.allocator = EMU_ALLOCATOR

    temp_data, _ := runtime.mem_alloc_non_zeroed(64 * 1024, allocator = EMU_ALLOCATOR)
    mem.arena_init(&EMU_TEMP_ARENA, temp_data)

    EMU_TEMP_ALLOCATOR = mem.arena_allocator(&EMU_TEMP_ARENA)
    EMU_CONTEXT.temp_allocator = EMU_TEMP_ALLOCATOR

    // -default-to-nil-allocator leaves the entry context with a nil allocator, so
    // install the guest arena before any new/append.
    context = EMU_CONTEXT

    trap_init() // route traps to the kernel before anything can cause one

    k: Kernel
    boot(&k) // register the initial processes
    schedule(&k)

    // Phase 3a milestone: the same machine, now running code that has no access
    // to any of the above except through a syscall.
    kprint("kernel: dropping to user mode\n")
    run_user(rawptr(hello_user), make([]u8, 16 * 1024))

    for p in k.processes {
        if p.mailbox.dropped > 0 {
            kprint("kernel: process %d lost %d message(s) to overflow\n", p.id, p.mailbox.dropped)
        }
    }
    kprint("kernel: idle, shutting down\n")
}

// --- Process model -------------------------------------------------------------
//
// A process is an actor: it owns private memory and reaches other processes only
// by message. Two kinds differ in who owns the loop:
//
//   Service -- the kernel owns the loop and calls on_message per message. The
//              process is stackless and runs to completion each turn, so state
//              that outlives a message lives in `user_state`. Cheap; the default.
//   Task    -- the process owns the loop, running on its own stack as a fiber.
//              It can block mid-computation (recv) or step aside (yield), so its
//              state lives in ordinary locals.
//
// Lifecycle: spawn -> Ready|Waiting -> (Ready <-> Waiting)* -> Dead.
// A service spawns Waiting (nothing to do until a message arrives); a task spawns
// Ready (it wants to run). A send into a Waiting process wakes it. A task that
// returns from its entry proc becomes Dead and the kernel reclaims its memory.

ProcessId :: distinct int

NO_PROCESS :: ProcessId(-1) // sender id for kernel-originated messages

ProcessKind :: enum {
    Service,
    Task,
}

ProcessState :: enum {
    Ready,   // wants CPU: a service with mail, or a runnable task
    Waiting, // blocked until a message arrives
    Dead,    // exited; memory reclaimed
}

MessageHandler :: proc(p: ^Process, msg: Message)
TaskEntry :: proc(p: ^Process)

Message :: struct {
    from: ProcessId,
    tag:  string, // message kind, e.g. "inc"
    data: []u8,   // payload bytes, owned by the receiving process
}

// --- Mailbox -------------------------------------------------------------------
//
// A mailbox is a fixed ring of slots with tag and payload stored inline, so a
// send neither allocates nor leaves anything to free and a process can never
// grow its way out of memory. Bulk data will need a separate memory-grant
// mechanism later; small inline messages are the microkernel norm.

MAILBOX_CAPACITY :: 16
MESSAGE_TAG_MAX :: 16
MESSAGE_DATA_MAX :: 64

Slot :: struct {
    from:     ProcessId,
    tag_len:  int,
    data_len: int,
    tag_buf:  [MESSAGE_TAG_MAX]u8,
    data_buf: [MESSAGE_DATA_MAX]u8,
}

Mailbox :: struct {
    slots:   [MAILBOX_CAPACITY]Slot,
    head:    int, // index of the oldest queued message
    count:   int,
    dropped: int, // lost to overflow; counted so loss is never silent
}

// What a full mailbox does with an arriving message.
Backpressure :: enum {
    // Refuse the send and tell the sender, which can then retry or back off.
    // Never destroys a message the system already accepted, so command order
    // and request/reply stay intact. The safe default.
    RejectNewest,
    // Evict the oldest to make room for the newest. For state and telemetry --
    // the latest mouse position matters, a stale backlog of them does not.
    DropOldest,
}

// Callee-saved CPU state for a fiber. Layout must match os/switch.S.
Context :: struct {
    ra: u64,
    sp: u64,
    s:  [12]u64,
    fs: [12]u64,
}

Process :: struct {
    id:     ProcessId,
    kind:   ProcessKind,
    state:  ProcessState,
    kernel: ^Kernel,

    // Service: the handler and the state it keeps between messages.
    on_message: MessageHandler,
    user_state: rawptr,

    // Task: entry point, saved CPU state, and the stack the fiber runs on.
    entry: TaskEntry,
    ctx:   Context,
    stack: []u8,

    // Every process owns its mailbox and the memory behind it: delivery copies
    // the message into the *receiver's* slots, so a process holds no pointer into
    // another's memory. That is also what real isolation will require later,
    // where copying across address spaces is mandatory.
    mailbox:      Mailbox,
    backpressure: Backpressure,

    // The most recently received message, copied out of the ring so its slot is
    // free immediately. A Message handed to a process points in here, and stays
    // valid until that process receives the next one.
    staging: Slot,

    // Backs the task stack and whatever the process allocates for itself.
    arena:     mem.Arena,
    allocator: mem.Allocator,
}

Kernel :: struct {
    processes: [dynamic]^Process,
    current:   ^Process,

    // The scheduler's own CPU state. A task switches here to give up the CPU.
    sched_ctx: Context,
}

// A task's stack is carved from its own arena, so the arena must be comfortably
// larger than the stack -- what is left is the room its mailbox and state grow
// into. Sizing them equal starves the mailbox.
PROCESS_ARENA_SIZE :: 64 * 1024
TASK_STACK_SIZE :: 16 * 1024

foreign import kernel_asm "system:kernel_asm"

@(default_calling_convention = "c")
foreign kernel_asm {
    ctx_switch :: proc(from: ^Context, to: ^Context) ---
    fiber_trampoline :: proc() ---
}

// First code to run on a new fiber's stack, reached from fiber_trampoline. Runs
// the task to completion, then parks it as Dead and leaves for good.
@(export)
fiber_main :: proc "c" (p: ^Process) {
    context = EMU_CONTEXT

    p.entry(p)

    p.state = .Dead
    ctx_switch(&p.ctx, &p.kernel.sched_ctx)
}

@(private)
process_init :: proc(k: ^Kernel, kind: ProcessKind, backpressure: Backpressure) -> ^Process {
    p := new(Process)
    p.id = ProcessId(len(k.processes))
    p.kind = kind
    p.kernel = k
    p.backpressure = backpressure

    backing, _ := runtime.mem_alloc_non_zeroed(PROCESS_ARENA_SIZE, allocator = EMU_ALLOCATOR)
    mem.arena_init(&p.arena, backing)
    p.allocator = mem.arena_allocator(&p.arena)

    append(&k.processes, p)
    return p
}

// Register a reactive service: the kernel calls `on_message` once per delivered
// message. `state` is an opaque pointer the handler owns; the kernel never looks
// inside it. Starts Waiting -- idle until someone sends to it.
spawn_service :: proc(
    k: ^Kernel,
    on_message: MessageHandler,
    state: rawptr = nil,
    backpressure := Backpressure.RejectNewest,
) -> ProcessId {
    p := process_init(k, .Service, backpressure)
    p.on_message = on_message
    p.user_state = state
    p.state = .Waiting
    return p.id
}

// Register an active task: `entry` runs on its own stack and owns its loop.
// Starts Ready. The context is seeded so the first switch into it "returns" into
// fiber_trampoline with s0 holding the process pointer.
spawn_task :: proc(
    k: ^Kernel,
    entry: TaskEntry,
    backpressure := Backpressure.RejectNewest,
) -> ProcessId {
    p := process_init(k, .Task, backpressure)
    p.entry = entry
    p.state = .Ready

    p.stack = make([]u8, TASK_STACK_SIZE, p.allocator)

    stack_top := uintptr(raw_data(p.stack)) + uintptr(len(p.stack))
    p.ctx.sp = u64(stack_top &~ uintptr(15)) // the ABI wants a 16-byte aligned sp
    p.ctx.ra = u64(uintptr(rawptr(fiber_trampoline)))
    p.ctx.s[0] = u64(uintptr(p))

    return p.id
}

// --- Messaging -----------------------------------------------------------------

// Copy a message into the receiver's mailbox. Returns false when it could not be
// delivered -- unknown or dead target, or a full mailbox under RejectNewest.
@(private)
deliver :: proc(k: ^Kernel, from, to: ProcessId, tag: string, data: []u8) -> bool {
    if int(to) < 0 || int(to) >= len(k.processes) do return false

    target := k.processes[int(to)]
    if target.state == .Dead do return false

    // Inline storage is fixed, so oversized messages are a programming error
    // rather than something to silently truncate.
    assert(len(tag) <= MESSAGE_TAG_MAX, "message tag exceeds MESSAGE_TAG_MAX")
    assert(len(data) <= MESSAGE_DATA_MAX, "message payload exceeds MESSAGE_DATA_MAX")

    mb := &target.mailbox

    if mb.count == MAILBOX_CAPACITY {
        switch target.backpressure {
        case .RejectNewest:
            mb.dropped += 1
            return false
        case .DropOldest:
            mb.head = (mb.head + 1) % MAILBOX_CAPACITY
            mb.count -= 1
            mb.dropped += 1
        }
    }

    slot := &mb.slots[(mb.head + mb.count) % MAILBOX_CAPACITY]
    slot.from = from
    slot.tag_len = len(tag)
    slot.data_len = len(data)
    copy(slot.tag_buf[:], transmute([]u8)tag)
    copy(slot.data_buf[:], data)
    mb.count += 1

    if target.state == .Waiting do target.state = .Ready
    return true
}

// Send from one process to another. False means the message was not delivered,
// which under RejectNewest is the sender's cue to retry or back off.
send :: proc(p: ^Process, to: ProcessId, tag: string, data: []u8 = nil) -> bool {
    return deliver(p.kernel, p.id, to, tag, data)
}

// Send a plain-old-data value as the payload. Pair with message_value to read it.
send_value :: proc(p: ^Process, to: ProcessId, tag: string, value: $T) -> bool {
    v := value
    return deliver(p.kernel, p.id, to, tag, slice.bytes_from_ptr(&v, size_of(T)))
}

// Post from the kernel itself, with no sending process (used by boot).
post :: proc(k: ^Kernel, to: ProcessId, tag: string, data: []u8 = nil) -> bool {
    return deliver(k, NO_PROCESS, to, tag, data)
}

post_value :: proc(k: ^Kernel, to: ProcessId, tag: string, value: $T) -> bool {
    v := value
    return deliver(k, NO_PROCESS, to, tag, slice.bytes_from_ptr(&v, size_of(T)))
}

// Reinterpret a message payload as a value of type T.
message_value :: proc(msg: Message, $T: typeid) -> T {
    assert(len(msg.data) >= size_of(T), "message payload smaller than requested type")
    return (cast(^T)raw_data(msg.data))^
}

// Take the oldest message, copying it into the process's staging slot so the ring
// position frees up right away. The returned Message points into that staging
// slot: it stays valid until this process receives its next message.
@(private)
mailbox_pop :: proc(p: ^Process) -> (msg: Message, ok: bool) {
    mb := &p.mailbox
    if mb.count == 0 do return {}, false

    p.staging = mb.slots[mb.head]
    mb.head = (mb.head + 1) % MAILBOX_CAPACITY
    mb.count -= 1

    return Message {
        from = p.staging.from,
        tag = string(p.staging.tag_buf[:p.staging.tag_len]),
        data = p.staging.data_buf[:p.staging.data_len],
    }, true
}

// --- Task-only primitives ------------------------------------------------------
// These suspend the caller, so only a fiber task may use them. A service is
// stackless and must return instead of blocking.

// Give up the CPU but stay runnable.
yield :: proc(p: ^Process) {
    assert(p.kind == .Task, "yield is only valid inside a task")
    p.state = .Ready
    ctx_switch(&p.ctx, &p.kernel.sched_ctx)
}

// Block until a message arrives, then take it.
recv :: proc(p: ^Process) -> Message {
    assert(p.kind == .Task, "recv is only valid inside a task")
    for p.mailbox.count == 0 {
        p.state = .Waiting
        ctx_switch(&p.ctx, &p.kernel.sched_ctx)
    }
    msg, _ := mailbox_pop(p)
    return msg
}

// Take a message if one is waiting; never blocks.
try_recv :: proc(p: ^Process) -> (Message, bool) {
    return mailbox_pop(p)
}

// Block until a message with `tag` arrives. Use this for request/reply, where
// unrelated mail may already be queued ahead of the response.
// NOTE: non-matching messages are discarded, not re-queued.
recv_tag :: proc(p: ^Process, tag: string) -> Message {
    for {
        msg := recv(p)
        if msg.tag == tag do return msg
        kprint("  [%d dropped %s while waiting for %s]\n", p.id, msg.tag, tag)
    }
}

// --- Scheduler -----------------------------------------------------------------

// Round-robin over the runnable processes until the system goes idle -- that is,
// until nothing is Ready. A service gets one message per turn; a task runs until
// it yields, blocks, or exits.
schedule :: proc(k: ^Kernel) {
    for {
        ran_something := false

        for p in k.processes {
            if p.state != .Ready do continue

            ran_something = true
            k.current = p

            switch p.kind {
            case .Service:
                if msg, ok := mailbox_pop(p); ok {
                    p.on_message(p, msg)
                }
                // Stay Ready while mail remains, so the next turn drains it.
                if p.mailbox.count == 0 && p.state == .Ready {
                    p.state = .Waiting
                }

            case .Task:
                ctx_switch(&k.sched_ctx, &p.ctx)
                if p.state == .Dead do process_free(p)
            }

            k.current = nil
        }

        if !ran_something do return
    }
}

// Release everything a dead process owns in one shot. The mailbox is inline
// storage that dies with the process; the stack and anything it allocated live
// in its arena.
@(private)
process_free :: proc(p: ^Process) {
    free_all(p.allocator)
    p.mailbox = {}
    p.stack = nil
}

// --- Utilities -----------------------------------------------------------------

kprint :: proc(format: string, args: ..any) {
    emu.print(fmt.tprintf(format, ..args))
}
