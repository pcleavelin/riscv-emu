/*
 * Link script for a user application.
 *
 * Every app links at the same base: each process has its own address space, so
 * there is nothing to collide with. The kernel maps these segments with the user
 * flag set, which is what makes them reachable from user mode and unreachable to
 * the supervisor's instruction fetch.
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x00010000, LENGTH = 16M
}

SECTIONS
{
    . = ORIGIN(RAM);

    .text ALIGN(0x1000) : {
        *(.text._start)
        *(.text .text.*)
    } > RAM

    .rodata ALIGN(0x1000) : {
        *(.rodata .rodata.*)
    } > RAM

    .data ALIGN(0x1000) : {
        *(.data .data.*)
    } > RAM

    .bss ALIGN(0x1000) : {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        /* Odin's random generator references thread-local support that a
         * freestanding app never reaches. Define it so the link resolves. */
        __tls_get_addr = .;
        __bss_end = .;
    } > RAM
}
