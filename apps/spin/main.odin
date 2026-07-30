package main

// A process that does not cooperate.
//
// Its loop makes no syscall at all: it does not yield, does not send, does not
// wait for a message. Under cooperative scheduling it would hold the CPU from the
// moment it started until the moment it finished, and every other process in the
// system -- including the ones doing useful work -- would simply stop.
//
// It still only gets a slice at a time, because the timer takes the CPU back
// whether the process agrees or not. The log lines from the other processes
// appearing in between the passes below are the whole point: nothing here yields
// to let them run.

import "../../sdk/app"

PASSES :: 3
WORK :: 8_000

@(export)
app_main :: proc() {
    app.log("spin: working, and yielding to nobody\n")

    for pass in 0 ..< PASSES {
        // A sum nothing needs, purely to take time. It is logged so that the
        // compiler cannot decide the loop was pointless and delete it.
        total := 0
        for i in 0 ..< WORK {
            total += i
        }

        app.logf("spin: pass %d done, total %d\n", pass, total)
    }

    app.exit(0)
}
