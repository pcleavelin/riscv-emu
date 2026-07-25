package kernel

// Boot policy: which processes the system starts with. Hardcoded for now --
// this is the hook that becomes a real launcher once user apps are loaded from
// their own ELFs at runtime.

boot :: proc(k: ^Kernel) {
    counter := new(Counter)
    counter.limit = 5

    counter_id := spawn_service(k, count_service, counter)
    ticker_id := spawn_task(k, ticker_task)

    // Hand the ticker the id of the service it drives.
    post_value(k, ticker_id, "config", counter_id)
}
