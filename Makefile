all: emu-gui std-lib emu-hello-example

emu-gui: src/*.odin src/**/*.odin
	mkdir -p bin
	odin build src/ -out:bin/emu

emu-core-tests: src/*.odin
	mkdir -p bin
	odin test src/emu_core/emu_core.odin -file -out:bin/emu

emu-hello-example:
	cd examples/hello_world && $(MAKE)

std-lib: stdlib/*.c stdlib/*.h stdlib/link.ld
	mkdir -p bin
	riscv64-none-elf-gcc -c stdlib/memops.S -ffreestanding -o bin/memops.o
	riscv64-none-elf-gcc -c stdlib/stdlib.c -ffreestanding -o bin/stdlib.o
	riscv64-none-elf-ld -T stdlib/link.ld bin/stdlib.o bin/memops.o -o bin/stdlib.elf
