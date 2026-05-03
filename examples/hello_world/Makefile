all: hello

hello: hello_obj
	riscv64-none-elf-ld -T ../link.ld out/*.o --just-symbols ../../bin/stdlib.elf -o out/hello_world.elf

hello_obj:
	mkdir -p out
	-rm out/*.o
	odin build . -target:linux_riscv64 -build-mode:object -default-to-nil-allocator -no-thread-local -no-rpath -no-entry-point -o:none -out:out/hello.o
