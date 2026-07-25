OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 512K
}

SECTIONS
{
    . = ORIGIN(RAM);

    .text ALIGN(0x8) : {
        *(.text._start)
        *(.text .text.*)
    } > RAM

    .rodata ALIGN(0x4000) : {
        *(.rodata .rodata.*)
    } > RAM

    .data ALIGN(0x4000) : {
        *(.data .data.*)
    } > RAM

    .bss ALIGN(0x4000) : {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        __tls_get_addr = .;
        __bss_end = .;
    } > RAM

    _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
