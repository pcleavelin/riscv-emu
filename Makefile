all: emu-gui std-lib examples

examples: emu-hello-example emu-host-to-guest-example

emu-gui: src/*.odin src/**/*.odin
	mkdir -p bin
	odin build src/ -out:bin/emu

emu-core-tests: src/*.odin
	mkdir -p bin
	odin test src/emu_core/emu_core.odin -file -out:bin/emu

std-lib: stdlib/*.c stdlib/*.h stdlib/link.ld
	mkdir -p bin
	riscv64-none-elf-gcc -c stdlib/memops.S -ffreestanding -o bin/memops.o
	riscv64-none-elf-gcc -c stdlib/stdlib.c -ffreestanding -fPIC -o bin/stdlib.o
	riscv64-none-elf-ld -T stdlib/link.ld bin/stdlib.o bin/memops.o -o bin/stdlib.elf

emu-hello-example:
	cd examples/hello_world && $(MAKE)
emu-host-to-guest-example:
	cd examples/host_to_guest && $(MAKE)
