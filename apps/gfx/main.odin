package main

// Something to look at.
//
// The app asks the kernel how big a frame is, takes a grant that size, draws into
// it, and asks for it to be shown. Nothing here knows whether the pixels end up as
// characters in a terminal or in a window -- that is the front end's business, and
// the whole point of the display being a device rather than an API.
//
// Presenting is not the same as sending. A sent grant changes hands and the sender
// loses it; a presented one is only read, so the same buffer is drawn into again
// for the next frame.

import "../../sdk/app"

FRAMES :: 24

// The ELF entry, which every app carries. The SDK cannot name the app's entry
// itself without declaring it foreign, and that does not survive an optimized
// build -- see sdk/app/start.odin.
@(link_name = "_start", linkage = "strong", require)
_start :: proc "c" () {
    app.start(app_main)
}

app_main :: proc() {
    width, height := app.display_size()
    app.logf("gfx: the display is %dx%d\n", width, height)

    frame, ok := app.grant_create(width * height * 4)
    if !ok {
        app.log("gfx: no grant for a frame\n")
        return
    }

    for n in 0 ..< FRAMES {
        draw(frame.data, width, height, n)

        if !app.present(frame) {
            app.log("gfx: the display would not take the frame\n")
            break
        }

        // Step aside between frames. Nothing here needs the CPU while the picture
        // is on screen, and the other processes have work to do.
        app.yield()
    }

    app.logf("gfx: drew %d frames\n", FRAMES)
    app.grant_drop(frame)
}

// A moving diagonal band, plus a box that walks across the frame. Neither means
// anything; between them they show that the picture is both animated and correctly
// oriented, which a still image would not.
draw :: proc(pixels: []u8, width, height, n: int) {
    box := (n * 2) % (width - 8)

    for y in 0 ..< height {
        for x in 0 ..< width {
            p := (y*width + x) * 4

            r := u8((x*4 + n*8) & 0xFF)
            g := u8((y*4 + n*4) & 0xFF)
            b := u8(((x + y)*2 + n*6) & 0xFF)

            // The box is opaque white, so it reads clearly against the band.
            if x >= box && x < box + 8 && y >= height/2 - 4 && y < height/2 + 4 {
                r, g, b = 0xFF, 0xFF, 0xFF
            }

            pixels[p + 0] = r
            pixels[p + 1] = g
            pixels[p + 2] = b
            pixels[p + 3] = 0xFF
        }
    }
}
