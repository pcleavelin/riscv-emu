package app

// The application SDK. Everything an app can do to the outside world goes through
// here, and everything here is a syscall -- a user process shares no memory with
// the kernel or with any other process.
//
// The surface deliberately mirrors the kernel's own actor API, so a driver written
// as a kernel service and an app written for user mode read the same way.

import "core:fmt"
import "core:slice"

import "../abi"

ProcessId :: distinct int

NO_PROCESS :: ProcessId(-1)

GrantId :: distinct int

NO_GRANT :: GrantId(abi.NO_GRANT)

Message :: struct {
    from:  ProcessId,
    tag:   string,
    data:  []u8,
    grant: GrantId, // NO_GRANT, or memory this message handed to us
}

// A block of memory that belongs to this process until it sends or drops it.
Grant :: struct {
    id:   GrantId,
    data: []u8,
}

foreign import app_asm "system:app_asm"

@(default_calling_convention = "c")
foreign app_asm {
    do_syscall :: proc(number: u64, arg0: u64, arg1: u64) -> i64 ---
}

// Where a received message lands. A Message points in here and stays valid until
// the next receive, the same contract the kernel gives its own processes.
@(private)
staging: abi.MessageBuf

// --- Lifecycle -----------------------------------------------------------------

// Leave for good. The kernel reclaims everything the process owns.
exit :: proc(code: int = 0) -> ! {
    do_syscall(abi.SYS_EXIT, u64(code), 0)
    for {} // the kernel never resumes us
}

// Give up the CPU but stay runnable.
yield :: proc() {
    do_syscall(abi.SYS_YIELD, 0, 0)
}

self :: proc() -> ProcessId {
    return ProcessId(do_syscall(abi.SYS_SELF, 0, 0))
}

// --- Messaging -----------------------------------------------------------------

// Send to another process. False means it was not delivered -- most often the
// target's mailbox is full, which is the cue to retry or back off rather than
// assume the message arrived.
send :: proc(to: ProcessId, tag: string, data: []u8 = nil) -> bool {
    return send_full(to, tag, data, NO_GRANT)
}

// Send, handing a block of memory over with the message. The grant stops being
// ours the moment this succeeds -- reading or writing `g.data` afterwards is a
// page fault, not a stale read, because the memory moves rather than being shared.
//
// A false return means nothing moved: the grant is still ours, still mapped where
// it was, so backing off and retrying is safe.
send_grant :: proc(to: ProcessId, tag: string, g: Grant, data: []u8 = nil) -> bool {
    return send_full(to, tag, data, g.id)
}

@(private)
send_full :: proc(to: ProcessId, tag: string, data: []u8, grant: GrantId) -> bool {
    assert(len(tag) <= abi.TAG_MAX, "message tag too long")
    assert(len(data) <= abi.DATA_MAX, "payload too large for a message; use a grant")

    buf: abi.MessageBuf
    buf.tag_len = i64(len(tag))
    buf.data_len = i64(len(data))
    buf.grant = i64(grant)
    copy(buf.tag[:], transmute([]u8)tag)
    copy(buf.data[:], data)

    return do_syscall(abi.SYS_SEND, u64(to), u64(uintptr(&buf))) == abi.OK
}

// Send a plain-old-data value as the payload. Pair with message_value to read it.
send_value :: proc(to: ProcessId, tag: string, value: $T) -> bool {
    v := value
    return send(to, tag, slice.bytes_from_ptr(&v, size_of(T)))
}

// Block until a message arrives.
recv :: proc() -> Message {
    for {
        if do_syscall(abi.SYS_RECV, u64(uintptr(&staging)), 0) == abi.OK {
            return message_from_buf(&staging)
        }
    }
}

// Take a message if one is waiting; never blocks.
try_recv :: proc() -> (Message, bool) {
    if do_syscall(abi.SYS_TRY_RECV, u64(uintptr(&staging)), 0) != abi.OK {
        return {}, false
    }
    return message_from_buf(&staging), true
}

// Block until a message with `tag` arrives. Use this for request/reply, where
// unrelated mail may already be queued ahead of the response.
// NOTE: non-matching messages are discarded, not re-queued.
recv_tag :: proc(tag: string) -> Message {
    for {
        msg := recv()
        if msg.tag == tag do return msg
    }
}

// Reinterpret a message payload as a value of type T.
message_value :: proc(msg: Message, $T: typeid) -> T {
    assert(len(msg.data) >= size_of(T), "message payload smaller than requested type")
    return (cast(^T)raw_data(msg.data))^
}

@(private)
message_from_buf :: proc(buf: ^abi.MessageBuf) -> Message {
    return Message {
        from = ProcessId(buf.from),
        tag = string(buf.tag[:buf.tag_len]),
        data = buf.data[:buf.data_len],
        grant = GrantId(buf.grant),
    }
}

// --- Grants --------------------------------------------------------------------
//
// A grant is how a buffer too big for a message travels: the kernel maps it into
// whoever owns it, and ownership moves on a send. Exactly one process can reach
// one at a time, so there is nothing to lock and no way for two processes to
// disagree about what it holds.

// Ask for `size` bytes of our own. The memory arrives zeroed and mapped, at an
// address the kernel picks.
grant_create :: proc(size: int) -> (Grant, bool) {
    info: abi.GrantInfo
    if do_syscall(abi.SYS_GRANT_CREATE, u64(size), u64(uintptr(&info))) != abi.OK {
        return {}, false
    }
    return grant_from_info(&info), true
}

// Take up a grant that arrived on a message. It is already ours at this point;
// this is what gives it an address in our address space.
grant_map :: proc(id: GrantId) -> (Grant, bool) {
    info: abi.GrantInfo
    if do_syscall(abi.SYS_GRANT_MAP, u64(id), u64(uintptr(&info))) != abi.OK {
        return {}, false
    }
    return grant_from_info(&info), true
}

// Give a grant up. Its memory goes back to the kernel, so `g.data` must not be
// touched again.
grant_drop :: proc(g: Grant) {
    do_syscall(abi.SYS_GRANT_DROP, u64(g.id), 0)
}

@(private)
grant_from_info :: proc(info: ^abi.GrantInfo) -> Grant {
    return Grant {
        id = GrantId(info.id),
        data = (([^]u8)(uintptr(info.addr)))[:info.size],
    }
}

// --- Processes -----------------------------------------------------------------

// Start another app by image name. The kernel loads it and returns its id.
spawn :: proc(image: string) -> (ProcessId, bool) {
    r := do_syscall(abi.SYS_SPAWN, u64(uintptr(raw_data(image))), u64(len(image)))
    if r < 0 do return NO_PROCESS, false
    return ProcessId(r), true
}

// --- Reactive apps -------------------------------------------------------------

// Hand the loop to the runtime: every message goes to `handler`. This is the
// common shape for a process that only reacts. An app that needs to do sustained
// work between messages should write its own loop around recv and try_recv.
run_service :: proc(handler: proc(msg: Message)) -> ! {
    for {
        handler(recv())
    }
}

// --- Diagnostics ---------------------------------------------------------------

log :: proc(msg: string) {
    do_syscall(abi.SYS_LOG, u64(uintptr(raw_data(msg))), u64(len(msg)))
}

logf :: proc(format: string, args: ..any) {
    log(fmt.tprintf(format, ..args))
}
