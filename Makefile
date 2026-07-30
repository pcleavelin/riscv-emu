all: emu-gui std-lib emu_os

emu_os:
	mkdir -p os/bin
	-rm os/bin/*.o
	-rm os/bin/*.elf
	odin build os -define:EMU_DEFAULT_START=false -target:freestanding_riscv64 -build-mode:object -default-to-nil-allocator -no-thread-local -no-rpath -no-crt -o:speed -out:os/bin/kernel.o
	riscv64-none-elf-gcc -c os/switch.S -ffreestanding -o os/bin/switch.o
	riscv64-none-elf-gcc -c os/trap.S -ffreestanding -o os/bin/trap.o
	riscv64-none-elf-gcc -c os/sbi.S -ffreestanding -o os/bin/sbi.o
	riscv64-none-elf-ld -T os/kernel.ld os/bin/kernel*.o os/bin/switch.o os/bin/trap.o os/bin/sbi.o --just-symbols bin/stdlib.elf -o os/bin/kernel.elf

emu_apps:
	mkdir -p apps/bin
	-rm apps/bin/*.o apps/bin/*.elf
	riscv64-none-elf-gcc -c sdk/app/syscall.S -ffreestanding -o apps/bin/syscall.o
	odin build apps/counter -target:freestanding_riscv64 -build-mode:object -default-to-nil-allocator -no-thread-local -no-rpath -no-crt -o:speed -out:apps/bin/counter.o
	riscv64-none-elf-ld -T sdk/app/link.ld apps/bin/counter*.o apps/bin/syscall.o -o apps/bin/counter.elf
	odin build apps/pixels -target:freestanding_riscv64 -build-mode:object -default-to-nil-allocator -no-thread-local -no-rpath -no-crt -o:speed -out:apps/bin/pixels.o
	riscv64-none-elf-ld -T sdk/app/link.ld apps/bin/pixels*.o apps/bin/syscall.o -o apps/bin/pixels.elf
	odin build apps/gfx -target:freestanding_riscv64 -build-mode:object -default-to-nil-allocator -no-thread-local -no-rpath -no-crt -o:speed -out:apps/bin/gfx.o
	riscv64-none-elf-ld -T sdk/app/link.ld apps/bin/gfx*.o apps/bin/syscall.o -o apps/bin/gfx.elf
	odin build apps/spin -target:freestanding_riscv64 -build-mode:object -default-to-nil-allocator -no-thread-local -no-rpath -no-crt -o:speed -out:apps/bin/spin.o
	riscv64-none-elf-ld -T sdk/app/link.ld apps/bin/spin*.o apps/bin/syscall.o -o apps/bin/spin.elf

examples: emu-hello-example emu-host-to-guest-example

emu-gui: src/*.odin src/**/*.odin
	mkdir -p bin
	odin build src/ -out:bin/emu

emu-core-tests: src/*.odin
	mkdir -p bin
	odin test src/emu_core/emu_core.odin -file -out:bin/emu

std-lib: stdlib/*.c stdlib/*.h stdlib/link.ld
	mkdir -p bin
	-rm bin/*.o
	riscv64-none-elf-gcc -c stdlib/memops.S -ffreestanding -o bin/memops.o
	riscv64-none-elf-gcc -c stdlib/stdlib.c -ffreestanding -fPIC -fno-builtin -o bin/stdlib.o
	riscv64-none-elf-ld -T stdlib/link.ld bin/stdlib.o bin/memops.o -o bin/stdlib.elf

emu-hello-example:
	cd examples/hello_world && $(MAKE)
emu-host-to-guest-example:
	cd examples/host_to_guest && $(MAKE)
