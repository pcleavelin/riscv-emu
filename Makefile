all: emu-gui

emu-gui: src/*.odin src/**/*.odin
	mkdir -p bin
	odin build src/ -out:bin/emu

emu-core-tests: src/*.odin
	mkdir -p bin
	odin test src/emu_core/emu_core.odin -file -out:bin/emu
