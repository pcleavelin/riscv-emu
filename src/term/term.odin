package term

// Showing a framebuffer in a terminal.
//
// A character cell is about twice as tall as it is wide, so one cell carries two
// pixels: the upper half block takes the foreground colour and the lower half is
// left to the background. A frame is therefore half as many rows as it is pixels
// tall, and comes out roughly square.
//
// This costs nothing, needs no window and no library, and works over ssh, which is
// the point. The limit is colour: it wants a terminal that understands 24-bit
// escape codes, and it redraws the whole frame every time.

import "core:fmt"
import "core:os"
import "core:strings"

UPPER_HALF_BLOCK :: "▀"

CURSOR_HOME :: "\e[H"
CURSOR_HIDE :: "\e[?25l"
CURSOR_SHOW :: "\e[?25h"
CLEAR_SCREEN :: "\e[2J"
RESET :: "\e[0m"

// Prepare the terminal to be drawn into. Clearing once up front means every frame
// after it can just go back to the top and overwrite.
start :: proc() {
    fmt.print(CLEAR_SCREEN, CURSOR_HIDE, sep = "")
}

// Give the terminal back to whoever comes next.
stop :: proc() {
    fmt.print(RESET, CURSOR_SHOW, "\n", sep = "")
}

// Draw one frame. Install this as the display's `show`.
//
// The whole frame is built into one buffer and written once: a write per pixel
// would make the terminal, not the emulator, the slow part.
show :: proc(width, height: int, pixels: []u8) {
    b: strings.Builder
    strings.builder_init(&b, context.temp_allocator)
    defer strings.builder_destroy(&b)

    strings.write_string(&b, CURSOR_HOME)

    for y := 0; y + 1 < height; y += 2 {
        for x in 0 ..< width {
            top := (y*width + x) * 4
            bottom := ((y + 1)*width + x) * 4

            // Foreground paints the top pixel, background the bottom one.
            fmt.sbprintf(&b, "\e[38;2;%d;%d;%dm", pixels[top], pixels[top + 1], pixels[top + 2])
            fmt.sbprintf(&b, "\e[48;2;%d;%d;%dm",
                pixels[bottom], pixels[bottom + 1], pixels[bottom + 2])
            strings.write_string(&b, UPPER_HALF_BLOCK)
        }

        strings.write_string(&b, RESET)
        strings.write_string(&b, "\n")
    }

    os.write_string(os.stdout, strings.to_string(b))
}
