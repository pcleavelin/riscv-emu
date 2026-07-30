package main

// Two halves of a handover, in one image.
//
// A message carries 64 bytes, which is nothing like a frame of pixels. This app
// paints one into a grant and hands it to another process, which is the shape the
// GUI will use: a client draws, a compositor receives, and the pixels themselves
// are never copied.
//
// Because a grant moves rather than being shared, a client that wants to draw a
// second frame into the same buffer has to be given it back first. So the two
// halves pass one buffer back and forth: paint, hand over, verify, hand back. That
// round trip is the price of the memory belonging to exactly one process at a
// time, and it is what a compositor's frame loop would actually look like here.
//
// Boot starts two processes from this one image and tells one of them to paint.
// Which half a process runs is decided by the first message it receives.

import "../../sdk/app"

WIDTH :: 64
HEIGHT :: 64
BYTES_PER_PIXEL :: 4
FRAME_SIZE :: WIDTH * HEIGHT * BYTES_PER_PIXEL

FRAMES :: 3 // how many times the buffer goes round

@(export)
app_main :: proc() {
    msg := app.recv()

    switch msg.tag {
    case "paint":
        paint(app.message_value(msg, app.ProcessId))

    case "frame":
        display(msg)

    case:
        app.logf("pixels: unexpected %s\n", msg.tag)
    }

    app.exit(0)
}

// The client half: paint a frame, hand it over, wait to get the buffer back, and
// paint the next one into it. Between the send and the return the memory is not
// ours at all -- touching it would fault rather than race.
paint :: proc(peer: app.ProcessId) {
    frame, ok := app.grant_create(FRAME_SIZE)
    if !ok {
        app.log("painter: no grant available\n")
        return
    }

    app.logf("painter: %d bytes at %x, sending %d frames\n",
        len(frame.data), uintptr(raw_data(frame.data)), FRAMES)

    for n in 0 ..< FRAMES {
        fill(frame.data, n)

        if !app.send_grant_value(peer, "frame", frame, n) {
            app.log("painter: the display would not take it\n")
            app.grant_drop(frame)
            return
        }

        // The buffer comes back on the reply, at whatever address the kernel
        // gives it this time.
        reply := app.recv_tag("return")
        frame, ok = app.grant_map(reply.grant)
        if !ok {
            app.log("painter: the frame did not come back\n")
            return
        }
    }

    app.logf("painter: %d frames done, buffer back at %x\n",
        FRAMES, uintptr(raw_data(frame.data)))

    app.send(peer, "done")
    app.grant_drop(frame)
}

// The compositor half: take each frame, check it, and give the buffer back so the
// client can draw the next one into it.
display :: proc(first: app.Message) {
    msg := first

    for {
        switch msg.tag {
        case "frame":
            frame, ok := app.grant_map(msg.grant)
            if !ok {
                app.log("display: could not map the frame\n")
                return
            }

            n := app.message_value(msg, int)
            wrong := check(frame.data, n)
            if wrong == 0 {
                app.logf("display: frame %d at %x, all %d pixels correct\n",
                    n, uintptr(raw_data(frame.data)), WIDTH * HEIGHT)
            } else {
                app.logf("display: frame %d has %d wrong bytes\n", n, wrong)
            }

            if !app.send_grant(msg.from, "return", frame) {
                app.log("display: could not give the buffer back\n")
                app.grant_drop(frame)
                return
            }

        case "done":
            app.log("display: no more frames\n")
            return
        }

        msg = app.recv()
    }
}

// A gradient that shifts with the frame number, so a stale buffer is not merely
// wrong somewhere -- it is a whole frame behind, and check() says which.
fill :: proc(pixels: []u8, n: int) {
    for y in 0 ..< HEIGHT {
        for x in 0 ..< WIDTH {
            p := (y*WIDTH + x) * BYTES_PER_PIXEL
            pixels[p + 0] = u8((x*4 + n) & 0xFF)
            pixels[p + 1] = u8((y*4 + n) & 0xFF)
            pixels[p + 2] = u8(((x ~ y)*4 + n) & 0xFF)
            pixels[p + 3] = 0xFF
        }
    }
}

check :: proc(pixels: []u8, n: int) -> (wrong: int) {
    for y in 0 ..< HEIGHT {
        for x in 0 ..< WIDTH {
            p := (y*WIDTH + x) * BYTES_PER_PIXEL
            if pixels[p + 0] != u8((x*4 + n) & 0xFF) do wrong += 1
            if pixels[p + 1] != u8((y*4 + n) & 0xFF) do wrong += 1
            if pixels[p + 2] != u8(((x ~ y)*4 + n) & 0xFF) do wrong += 1
            if pixels[p + 3] != 0xFF do wrong += 1
        }
    }
    return
}
