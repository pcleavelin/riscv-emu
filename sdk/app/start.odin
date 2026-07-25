package app

// Process startup. The kernel maps the image, a heap and a stack, then enters
// here in user mode. This brings up the Odin runtime over the heap the kernel
// provided and calls the app's entry point.

import "base:runtime"
import "core:mem"
import "core:slice"

import "../abi"

@(private)
HEAP_ARENA: mem.Arena
@(private)
TEMP_ARENA: mem.Arena

// The app's context, holding the allocators backed by the heap the kernel mapped.
// _start installs it before calling app_main, which inherits it.
CONTEXT: runtime.Context

TEMP_SIZE :: 64 * 1024

// Every app defines this. Declaring it with Odin's own calling convention means
// it takes the implicit context parameter, so the runtime _start installs is
// already in place when the app's code runs -- an app never touches `context`.
foreign import app_entry "system:app_entry"

@(default_calling_convention = "odin")
foreign app_entry {
    app_main :: proc() ---
}

@(export)
_start :: proc "c" () {
    // A "c" entry point carries no context, and the calls below need one before
    // the real allocators exist. Nothing here allocates through it.
    context = runtime.default_context()

    heap := slice.bytes_from_ptr(rawptr(uintptr(abi.USER_HEAP_BASE)), abi.USER_HEAP_SIZE)
    mem.arena_init(&HEAP_ARENA, heap)
    CONTEXT.allocator = mem.arena_allocator(&HEAP_ARENA)

    temp, _ := runtime.mem_alloc_non_zeroed(TEMP_SIZE, allocator = CONTEXT.allocator)
    mem.arena_init(&TEMP_ARENA, temp)
    CONTEXT.temp_allocator = mem.arena_allocator(&TEMP_ARENA)

    context = CONTEXT

    app_main()

    // Returning from app_main is a normal, successful exit.
    exit(0)
}
