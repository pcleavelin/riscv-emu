package kernel

// Boot policy: which processes the system starts with. Hardcoded for now -- this
// is the hook that becomes a real launcher, and it is already the only place that
// decides whether a process runs in the kernel or in user mode.
//
// Both counters below answer the same protocol, and each is driven by its own copy
// of the same ticker task, which cannot tell them apart. One is a stackless kernel
// service reached by a procedure call. The other is a separately linked ELF running
// in user mode in an address space of its own, reached only by syscall and message.

boot :: proc(k: ^Kernel) {
    counter := new(Counter)
    counter.limit = 5

    kernel_counter := spawn_service(k, count_service, counter)
    post_value(k, spawn_task(k, ticker_task), "config", kernel_counter)

    user_counter, ok := spawn_user(k, "counter")
    if !ok {
        kprint("boot: cannot start the counter app\n")
        return
    }

    post_value(k, spawn_task(k, ticker_task), "config", user_counter)
}
