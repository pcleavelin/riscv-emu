package app

// Process startup. The kernel maps the image, a heap and a stack, then enters the
// app's `_start` in user mode. That hands control straight here, which brings up
// the Odin runtime over the heap the kernel provided and calls the app's entry.
//
// The app passes its entry point in rather than the SDK declaring it `foreign`.
// A foreign declaration would name a symbol the app also defines, and an
// optimized build compiles the whole program to one object, where a declaration
// and a definition of the same name cannot coexist -- the declaration wins and
// the app's code is dropped. Passing a procedure keeps the dependency in the
// language, where the compiler can see it and nothing can quietly eliminate it.

import "base:runtime"
import "core:mem"
import "core:slice"

import "../abi"

@(private)
HEAP_ARENA: mem.Arena
@(private)
TEMP_ARENA: mem.Arena

// The app's context, holding the allocators backed by the heap the kernel mapped.
// start installs it before calling the app's entry, which inherits it.
CONTEXT: runtime.Context

TEMP_SIZE :: 64 * 1024

// Bring the runtime up and run the app. `entry` is declared with Odin's own
// calling convention, so it takes the implicit context parameter and the app's
// code never has to touch `context` itself.
//
// Does not return: an app leaves by exiting, and returning from its entry is a
// successful exit.
start :: proc "c" (entry: proc()) {
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

    entry()

    exit(0)
}
