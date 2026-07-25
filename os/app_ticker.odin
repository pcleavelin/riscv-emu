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

    // Burst without yielding, so the service gets no chance to drain. Delivery
    // stops at MAILBOX_CAPACITY and the rest come back refused -- refused, not
    // silently discarded, which is the whole point of reject-newest.
    accepted, refused := 0, 0
    for _ in 0 ..< MAILBOX_CAPACITY + 4 {
        if send(p, counter, "inc") {
            accepted += 1
        } else {
            refused += 1
        }
    }
    kprint("ticker: burst accepted=%d refused=%d\n", accepted, refused)

    // Its mailbox is full, so this request would be refused too. Yield until it
    // has drained enough to accept -- a well-behaved sender backs off rather
    // than dropping work on the floor.
    for !send(p, counter, "get") {
        yield(p)
    }

    // Selective receive: unrelated mail may be queued ahead of the reply.
    reply := recv_tag(p, "value")
    kprint("ticker: final value = %d\n", message_value(reply, int))
}
