package main

// A user-mode counter, written the way an app author would write it.
//
// Nothing here knows about page tables, trap frames or scheduling, and there is
// no runtime setup to perform: the SDK's entry point brings the allocator up
// before calling app_main.
//
// It answers the same protocol as the kernel's own counter service in
// os/app_counter.odin, and the same ticker drives both. Reading the two side by
// side is the point: the privilege boundary changes none of the code.

import "../../sdk/app"

Counter :: struct {
    count:   int,
    limit:   int,
    stopped: bool,
}

// The initializer puts this in .data rather than .bss, so a working count also
// says the loader copied the file-backed part of the image correctly.
state := Counter{limit = 5}

@(export)
app_main :: proc() {
    app.log("counter(user): ready\n")

    // The reactive shape: hand the loop to the runtime and just answer messages.
    app.run_service(on_message)
}

on_message :: proc(msg: app.Message) {
    switch msg.tag {
    case "inc":
        state.count += 1
        app.logf("  counter(user): count = %d\n", state.count)

        // Steer the caller: tell the ticker when we have had enough rather than
        // letting it decide. Once is enough -- repeating it would just fill the
        // ticker's mailbox with redundant mail.
        if state.count >= state.limit && !state.stopped {
            state.stopped = true
            app.send(msg.from, "stop")
        }

    case "get":
        app.send_value(msg.from, "value", state.count)

    case "quit":
        app.logf("counter(user): finished at %d\n", state.count)
        app.exit(0)

    case:
        app.logf("counter(user): ignoring %s\n", msg.tag)
    }
}
