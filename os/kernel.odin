package kernel

// The OS kernel image, entered from the emulator's boot vector. _start brings up
// the guest allocator, then hands control to the actor scheduler. The initial
// actors are registered by boot() (see the app files); once user apps load from
// their own ELFs at runtime, that hook becomes a real launcher.

import "base:runtime"
import "core:mem"
import "core:slice"
import "core:strings"

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

    k: Kernel
    boot(&k) // register the initial actors
    run(&k)  // drain messages until the system goes idle
}

// --- Actor runtime -------------------------------------------------------------
//
// Phase 1: run-to-completion actors. An actor is a message handler; the scheduler
// drains a FIFO of envelopes, dispatching each to its target's behavior. An actor
// keeps state between messages in `state` and reaches other actors only through
// `send` -- no shared calls, no blocking. Cooperative fibers (blocking recv) and
// real isolation (privilege traps, then paging) come in later phases behind this
// same spawn/send API.

ActorId :: distinct int

Message :: struct {
    from: ActorId,
    tag:  string, // message kind, e.g. "ping"
    data: []u8,   // payload bytes, copied into kernel memory by send
}

Behavior :: proc(k: ^Kernel, self: ActorId, msg: Message)

Actor :: struct {
    behavior: Behavior,
    state:    rawptr,
    alive:    bool,
}

Envelope :: struct {
    to:  ActorId,
    msg: Message,
}

Kernel :: struct {
    actors: [dynamic]Actor,
    queue:  [dynamic]Envelope,
}

// Register a new actor and return its id. `state` is an opaque per-actor pointer
// the behavior owns; the kernel never looks inside it.
spawn :: proc(k: ^Kernel, behavior: Behavior, state: rawptr = nil) -> ActorId {
    append(&k.actors, Actor{behavior = behavior, state = state, alive = true})
    return ActorId(len(k.actors) - 1)
}

// Enqueue a message for `to`, stamped with the sender. tag and data are copied
// into kernel-owned memory so the caller can reuse its buffers immediately.
// NOTE: that memory is not reclaimed yet -- a freeing mailbox allocator is a
// later task (the arena only grows).
send :: proc(k: ^Kernel, from, to: ActorId, tag: string, data: []u8 = nil) {
    owned_data: []u8
    if len(data) > 0 {
        owned_data = make([]u8, len(data))
        copy(owned_data, data)
    }
    append(&k.queue, Envelope{
        to  = to,
        msg = Message{from = from, tag = strings.clone(tag), data = owned_data},
    })
}

// Send a plain-old-data value as the payload. Pair with message_value to read it.
send_value :: proc(k: ^Kernel, from, to: ActorId, tag: string, value: $T) {
    v := value
    send(k, from, to, tag, slice.bytes_from_ptr(&v, size_of(T)))
}

// Reinterpret a message payload as a value of type T.
message_value :: proc(msg: Message, $T: typeid) -> T {
    assert(len(msg.data) >= size_of(T), "message payload smaller than requested type")
    return (cast(^T)raw_data(msg.data))^
}

// Drain the queue until no messages remain, dispatching each to its target's
// behavior. Behaviors may send more messages, which extend the same queue.
run :: proc(k: ^Kernel) {
    for len(k.queue) > 0 {
        env := k.queue[0]
        ordered_remove(&k.queue, 0)

        actor := k.actors[int(env.to)]
        if actor.alive {
            actor.behavior(k, env.to, env.msg)
        }
    }
}
