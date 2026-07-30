package main

// Two halves of a handover, in one image.
//
// A message carries 64 bytes, which is nothing like a frame of pixels. This app
// paints one into a grant and hands it to another process, which is the shape the
// GUI will use: a client draws, a compositor receives, and the pixels themselves
// are never copied.
//
// Boot starts two processes from this one image and tells one of them to paint.
// Which half a process runs is decided by the first message it receives.

import "../../sdk/app"

WIDTH :: 64
HEIGHT :: 64
BYTES_PER_PIXEL :: 4
FRAME_SIZE :: WIDTH * HEIGHT * BYTES_PER_PIXEL

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

// Fill a frame and hand it to `peer`. After the send the memory is not ours: the
// buffer is unmapped, and touching it would fault rather than race.
paint :: proc(peer: app.ProcessId) {
    frame, ok := app.grant_create(FRAME_SIZE)
    if !ok {
        app.log("painter: no grant available\n")
        return
    }

    app.logf("painter: painting %d bytes at %x\n", len(frame.data), uintptr(raw_data(frame.data)))

    for y in 0 ..< HEIGHT {
        for x in 0 ..< WIDTH {
            p := (y*WIDTH + x) * BYTES_PER_PIXEL
            frame.data[p + 0] = u8(x * 4) // a gradient, so a wrong byte is a wrong picture
            frame.data[p + 1] = u8(y * 4)
            frame.data[p + 2] = u8((x ~ y) * 4)
            frame.data[p + 3] = 0xFF
        }
    }

    if !app.send_grant(peer, "frame", frame) {
        app.log("painter: the display would not take it\n")
        app.grant_drop(frame)
        return
    }

    app.log("painter: handed the frame over\n")
}

// Take a frame someone painted and check it arrived intact.
display :: proc(msg: app.Message) {
    frame, ok := app.grant_map(msg.grant)
    if !ok {
        app.log("display: could not map the frame\n")
        return
    }

    app.logf("display: got %d bytes at %x from process %d\n",
        len(frame.data), uintptr(raw_data(frame.data)), int(msg.from))

    // Read every pixel back. The painter is gone by now, so if the bytes are
    // right, the memory really moved rather than being copied or shared.
    wrong := 0
    for y in 0 ..< HEIGHT {
        for x in 0 ..< WIDTH {
            p := (y*WIDTH + x) * BYTES_PER_PIXEL
            if frame.data[p + 0] != u8(x * 4) do wrong += 1
            if frame.data[p + 1] != u8(y * 4) do wrong += 1
            if frame.data[p + 2] != u8((x ~ y) * 4) do wrong += 1
            if frame.data[p + 3] != 0xFF do wrong += 1
        }
    }

    if wrong == 0 {
        app.logf("display: all %d pixels correct\n", WIDTH * HEIGHT)
    } else {
        app.logf("display: %d bytes wrong\n", wrong)
    }

    app.grant_drop(frame)
}
