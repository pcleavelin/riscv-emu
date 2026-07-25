package main

// A user-mode counter, written the way an app author would write it.
//
// Nothing here knows about page tables, trap frames or scheduling, and there is
// no runtime setup to perform: the SDK's entry point brings the allocator up
// before calling app_main.

import "../../sdk/app"

Counter :: struct {
    count: int,
}

state: Counter

@(export)
app_main :: proc() {
    app.log("counter: ready\n")

    // The reactive shape: hand the loop to the runtime and just answer messages.
    app.run_service(on_message)
}

on_message :: proc(msg: app.Message) {
    switch msg.tag {
    case "inc":
        state.count += 1

    case "get":
        app.send_value(msg.from, "value", state.count)

    case "quit":
        app.logf("counter: finished at %d\n", state.count)
        app.exit(0)

    case:
        app.logf("counter: ignoring %s\n", msg.tag)
    }
}
