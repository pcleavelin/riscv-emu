package kernel

// Example app: an active task.
//
// It owns its loop and runs on its own stack, so ordinary locals (`counter`,
// `ticks`) survive across suspension -- no state struct needed. It blocks for
// startup config, works in a loop while polling for a stop message, and blocks
// again for a reply. Returning from this proc exits the process.

ticker_task :: proc(p: ^Process) {
    // Block until boot hands us the counter to drive.
    cfg := recv(p)
    counter := message_value(cfg, ProcessId)

    ticks := 0
    for {
        // Poll without blocking: the counter tells us when to stop.
        if msg, ok := try_recv(p); ok && msg.tag == "stop" {
            kprint("ticker: stop after %d ticks\n", ticks)
            break
        }

        send(p, counter, "inc")
        ticks += 1

        // Step aside so the counter can run; we stay runnable.
        yield(p)
    }

    // Blocking request/reply. It must be a selective receive: a late "stop" can
    // already be queued ahead of the reply we want.
    send(p, counter, "get")
    reply := recv_tag(p, "value")
    kprint("ticker: final value = %d\n", message_value(reply, int))
}
