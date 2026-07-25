package emu_bindings

import "base:runtime"
import "core:mem"
import "core:slice"
import "core:strings"

// EMU_NATIVE swaps the comm-stack primitives from the emulator's foreign
// emu_stdlib (the RISC-V guest runtime) to an in-process pure-Odin stack, so the
// editor source can be compiled and run on the host with no VM. The host
// harness (src/nativetest) installs native_host_dispatch to service call_host_fn
// and capture the draw stream -- this is how the VM run is checked against a
// native run of the same source.  Build the VM guest as usual (flag off); build
// the native harness with `-define:EMU_NATIVE=true`.
EMU_NATIVE :: #config(EMU_NATIVE, false)

EMU_DEFAULT_START :: #config(EMU_DEFAULT_START, true)

when !EMU_NATIVE {
    foreign import emu_stdlib "system:emu_stdlib"

    @(default_calling_convention = "c")
    foreign emu_stdlib {
        emu_syscall :: proc() ---
        emu_out_call_host_fn :: proc(buf: ^u8, len: int) ---

        emu_out_push_u32 :: proc(val: u32) ---
        emu_out_push_u64 :: proc(val: u64) ---

        emu_out_pop_u32 :: proc() -> u32 ---
        emu_out_pop_u64 :: proc() -> u64 ---

        emu_in_read_line :: proc(buf: ^^u8, len: ^u64) -> u8 ---
    }
} else {
    @(private) comm_buf: [4096]u64
    @(private) comm_sp:  int

    // The native harness installs this to receive call_host_fn dispatches; it
    // pops the just-pushed args and emits the draw golden.
    native_host_dispatch: proc(name: string)

    emu_out_push_u32 :: proc(val: u32) { comm_buf[comm_sp] = u64(val); comm_sp += 1 }
    emu_out_push_u64 :: proc(val: u64) { comm_buf[comm_sp] = val;      comm_sp += 1 }
    emu_out_pop_u32  :: proc() -> u32  { comm_sp -= 1; return u32(comm_buf[comm_sp]) }
    emu_out_pop_u64  :: proc() -> u64  { comm_sp -= 1; return comm_buf[comm_sp] }

    emu_out_call_host_fn :: proc(buf: ^u8, len: int) {
        name := strings.string_from_ptr(buf, len)
        if native_host_dispatch != nil do native_host_dispatch(name)
    }

    emu_in_read_line :: proc(buf: ^^u8, len: ^u64) -> u8 { return 1 }
    emu_syscall :: proc() {}
}

MainProc :: proc()

// The VM entry point: lives at a fixed guest address and bootstraps the guest
// arena. Native builds don't run it (the host harness sets EMU_CONTEXT itself),
// and exporting _start would also collide with the C runtime's _start.
when !EMU_NATIVE && EMU_DEFAULT_START {
    EMU_ARENA: mem.Arena
    EMU_TEMP_ARENA: mem.Arena

    EMU_ALLOCATOR: mem.Allocator
    EMU_TEMP_ALLOCATOR: mem.Allocator

    EMU_CONTEXT: runtime.Context

    @(export)
    _start :: proc() {
        data := slice.bytes_from_ptr(rawptr(uintptr(0x4000)), 1024 * 1024 * 256)
        mem.arena_init(&EMU_ARENA, data)

        EMU_ALLOCATOR = mem.arena_allocator(&EMU_ARENA)
        EMU_CONTEXT.allocator = EMU_ALLOCATOR

        temp_data, _ := runtime.mem_alloc_non_zeroed(1024*1024, allocator = EMU_ALLOCATOR)
        mem.arena_init(&EMU_TEMP_ARENA, temp_data)

        EMU_TEMP_ALLOCATOR = mem.arena_allocator(&EMU_TEMP_ARENA)
        EMU_CONTEXT.temp_allocator = EMU_TEMP_ALLOCATOR

        print("_start called\n")

        emu_out_push_u64(0xBADBEEF)
    }
}

push_string :: proc "contextless" (str: string) {
    emu_out_push_u32(u32(len(str)))
    emu_out_push_u64(u64(uintptr(transmute(^u8)raw_data(str))))
}

pop_string :: proc() -> string {
    str_addr := emu_out_pop_u64()
    str_len := emu_out_pop_u32()

    return strings.string_from_ptr(transmute(^u8)uintptr(str_addr), int(str_len))
}

HostArg :: union {
    u32,
    u64,
    string
}
call_host_fn :: proc "contextless" (fn: string, args: ..HostArg) {
    i := len(args)
    for {
        if i <= 0 { break }
        i -= 1

        switch v in args[i] {
            case u32: {
                emu_out_push_u32(v)
            }
            case u64: {
                emu_out_push_u64(v)
            }
            case string: {
                push_string(v)
            }
        }
    }

    emu_out_call_host_fn(transmute(^u8)raw_data(fn), len(fn))
}

print :: proc "contextless" (str: string) {
    emu_out_push_u32(u32(len(str)))
    emu_out_push_u64(u64(uintptr(transmute(^u8)raw_data(str))))

    func_str := "core::println"
    emu_out_call_host_fn(transmute(^u8)raw_data(func_str), len(func_str))
}

readln :: proc() -> (val: string) {
    buf: ^u8
    len: u64

    if emu_in_read_line(&buf, &len) > 0 do return

    return string(slice.bytes_from_ptr(buf, int(len)))
}
