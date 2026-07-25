package kernel

// Example app: a reactive service.
//
// It has no loop of its own -- the kernel calls count_service once per message
// and the handler returns immediately. Everything that must survive between
// messages lives in Counter, because a service has no stack to keep locals on.
// This is the cheap, common shape: most processes only react.

Counter :: struct {
    count: int,
    limit: int,
}

count_service :: proc(p: ^Process, msg: Message) {
    c := cast(^Counter)p.user_state

    switch msg.tag {
    case "inc":
        c.count += 1
        kprint("  counter: count = %d\n", c.count)

        // Services can steer their callers: tell the ticker when we have had
        // enough rather than letting it decide.
        if c.count >= c.limit {
            send(p, msg.from, "stop")
        }

    case "get":
        send_value(p, msg.from, "value", c.count)

    case:
        kprint("  counter: ignoring %s\n", msg.tag)
    }
}
