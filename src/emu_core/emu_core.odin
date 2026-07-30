package emu_core

import "base:runtime"
import "core:os"
import "core:testing"
import "core:fmt"
import "core:math/bits"
import "core:mem"
import "core:strings"

REG_X2 :: 2
REG_RA :: 1 // x1, the return-address register

// Power-off vector installed in ra before the bootloader runs. A top-level `ret`
// lands here and emu_step reports .Halt. Chosen to sit far above any guest memory
// so it is never a valid instruction address.
EMU_HALT_VECTOR :: u64(0xFFFF_FFFF_FFFF_FFF0)

// Initial guest stack pointer, installed in sp by emu_boot. The stack grows down
// from the top of the kernel's 1GB region, well above the image and its heap, so
// everything the kernel touches sits in the one region it identity maps.
EMU_STACK_TOP :: u64(0xC000_0000)

// Why the machine stopped advancing. emu_run stops on any value other than .None.
StopReason :: enum {
    None,    // advanced normally; keep running
    Halt,    // clean shutdown: SYS_SHUTDOWN, or pc reached EMU_HALT_VECTOR
    Trap,    // SYS_TRAP ecall — the guest signalled a fatal trap
    Invalid, // undecodable instruction
}

// Privilege levels, encoded as RISC-V numbers them. The layers map onto the
// hardware model directly: the host is the machine/firmware layer that services
// an S-mode ecall (the SBI role), the guest kernel runs in S, and processes run
// in U and trap into the kernel.
PrivilegeMode :: enum u8 {
    User       = 0,
    Supervisor = 1,
    Machine    = 3,
}

// Supervisor CSRs, at their architectural addresses.
CSR_SSTATUS  :: 0x100
CSR_SIE      :: 0x104
CSR_STVEC    :: 0x105
CSR_SSCRATCH :: 0x140
CSR_SEPC     :: 0x141
CSR_SCAUSE   :: 0x142
CSR_STVAL    :: 0x143
CSR_SIP      :: 0x144
CSR_SATP     :: 0x180

// sstatus bits used by trap entry and exit.
SSTATUS_SIE  :: u64(1) << 1 // supervisor interrupts enabled
SSTATUS_SPIE :: u64(1) << 5 // interrupt-enable state saved on trap entry
SSTATUS_SPP  :: u64(1) << 8  // privilege level the trap came from (1 = S, 0 = U)
SSTATUS_SUM  :: u64(1) << 18 // permit supervisor loads and stores to user pages

// An interrupt is distinguished from an exception by the top bit of scause; the
// rest of the value says which interrupt.
CAUSE_INTERRUPT :: u64(1) << 63
IRQ_S_TIMER     :: u64(5)

// The timer's bit in sie and sip, at the interrupt number's position.
SIE_STIE :: u64(1) << 5
SIP_STIP :: u64(1) << 5

// scause values for the traps the emulator raises.
CAUSE_ECALL_FROM_U   :: u64(8)
CAUSE_ILLEGAL_INSTR  :: u64(2)
CAUSE_FETCH_PAGE_FAULT :: u64(12)
CAUSE_LOAD_PAGE_FAULT  :: u64(13)
CAUSE_STORE_PAGE_FAULT :: u64(15)

// --- Sv39 paging ---------------------------------------------------------------
//
// A 39-bit virtual address splits into three 9-bit page-table indices and a
// 12-bit offset, so a walk is three levels deep over 4KB pages. A leaf found
// above the last level is a superpage covering 2MB or 1GB, which is what makes an
// identity map cheap to build.

PAGE_SIZE :: u64(4096)
PAGE_SHIFT :: uint(12)
PTE_SIZE :: u64(8)
PTE_PER_PAGE :: u64(512)

SATP_MODE_BARE :: u64(0)
SATP_MODE_SV39 :: u64(8)

// Page table entry flags.
PTE_V :: u64(1) << 0 // valid
PTE_R :: u64(1) << 1 // readable
PTE_W :: u64(1) << 2 // writable
PTE_X :: u64(1) << 3 // executable
PTE_U :: u64(1) << 4 // reachable from user mode
PTE_A :: u64(1) << 6 // accessed
PTE_D :: u64(1) << 7 // dirty

// What a memory access is for. Each requires a different permission bit, and
// faults with a different cause.
MemAccess :: enum {
    Fetch,
    Load,
    Store,
}

Emu64 :: struct {
    reg: [31]u64,
    // Floating-point register file (F/D extension). f0..f31, each holding raw
    // bits: an f64 fills all 64, an f32 is NaN-boxed in the low 32.
    freg: [32]u64,
    pc: u64,

    page_table: EmuPageTable,
    page_arena: mem.Arena,

    host_functions: map[string]HostFunction,
    comm_stack: [64]EmuValue,
    comm_stack_num: int,

    // Set to .Invalid at the start of each emu_step; the ecall handlers overwrite
    // it with .Halt or .Trap. emu_step reports it when the evaluator halts.
    stop_reason: StopReason,

    // Current privilege level. The machine boots in Supervisor: the guest kernel
    // is the first thing to run, and its ecalls go out to the host as SBI calls.
    mode: PrivilegeMode,

    // Supervisor control registers, indexed by CSR address.
    csr: map[u16]u64,

    // A page fault raised part-way through an instruction. Translation happens
    // deep inside the memory accessors, which cannot report failure, so a fault
    // is recorded here and emu_step delivers it once the instruction finishes.
    // Delivery is therefore precise for a fetch fault but only approximate for a
    // load or store, which may already have written a register.
    fault_pending: bool,
    fault_cause:   u64,
    fault_addr:    u64,

    // The machine's whole notion of time: one tick per instruction retired. The
    // guest asks to be interrupted at a deadline and the timer fires when the
    // count reaches it, which makes preemption reproducible -- the same program
    // is preempted in the same places on every run, however fast the host is.
    ticks:          u64,
    timer_deadline: u64,
    timer_armed:    bool,

    // The framebuffer, and how it reaches a screen.
    display: Display,

    // Application images the guest kernel has asked for, keyed by image name.
    // Serving them from here rather than re-reading the file keeps the size a
    // read sees identical to the size already reported.
    image_cache: map[string][]u8,
}

HostFn :: proc(emu: ^Emu64, user_data: rawptr) -> (ok: bool)
HostFunction :: struct {
    fn: HostFn,
    user_data: rawptr,
}

EmuPageTable :: struct {
    page_size: u64,
    pages: map[u64]EmuMemoryPage,
}

EmuMemoryPage :: struct {
    start_addr: u64,
    virtual_mem: []u8,
}

EmuInstruction32:: struct #raw_union {
    raw_instruction: u32,
    opcode: EmuInstructionOpcode,
    r_type: EmuInstructionRType32,
    i_type: EmuInstructionIType32,
    s_type: EmuInstructionSType32,
    b_type: EmuInstructionBType32,
    u_type: EmuInstructionUType32,
    j_type: EmuInstructionJType32,
}

EmuInstructionOpcode :: bit_field u8 {
    v: u8 | 7,
}

EmuInstructionRType32 :: bit_field u32 {
    _opcode: u8 | 7,
    rd:      u8 | 5,
    funct_3: u8 | 3,
    rs1:     u8 | 5,
    rs2:     u8 | 5,
    funct_7: u8 | 7,
}

EmuInstructionIType32 :: bit_field u32 {
    _opcode: u8  | 7,
    rd:      u8  | 5,
    funct_3: u8  | 3,
    rs1:     u8  | 5,
    imm:     u16 | 12,
}

EmuInstructionSType32 :: bit_field u32 {
    _opcode: u8 | 7,
    imm_lo:  u8 | 5,
    funct_3: u8 | 3,
    rs1:     u8 | 5,
    rs2:     u8 | 5,
    imm_hi:  u8 | 7,
}

EmuInstructionBType32 :: bit_field u32 {
    _opcode:   u8 | 7,
    imm_lo:    u8 | 5,
    funct_3:   u8 | 3,
    rs1:       u8 | 5,
    rs2:       u8 | 5,
    imm_hi:    u8 | 7,
}

EmuInstructionUType32 :: bit_field u32 {
    _opcode: u8  | 7,
    rd:      u8  | 5,
    imm:     u32 | 20,
}

EmuInstructionJType32 :: bit_field u32 {
    _opcode: u8  | 7,
    rd:      u8  | 5,
    imm_hi:  u8  | 8,
    imm_mid: u8  | 1,
    imm_lo:  u16 | 10,
    imm_msb: u8  | 1,
}

// --- Decoded Instruction Types ---

InstrMnemonic :: enum u8 {
    INVALID,

    // RV64I / RV32I
    LUI, AUIPC,
    JAL, JALR,
    BEQ, BNE, BLT, BGE, BLTU, BGEU,
    LB, LH, LW, LD, LBU, LHU, LWU,
    SB, SH, SW, SD,
    ADDI, SLTI, SLTIU, XORI, ORI, ANDI, SLLI, SRLI, SRAI,
    ADD, SUB, SLL, SLT, SLTU, XOR, SRL, SRA, OR, AND,
    MUL, MULH, MULHSU, MULHU, DIV, DIVU, REM, REMU,
    ADDIW, SLLIW, SRLIW, SRAIW,
    ADDW, SUBW, MULW, SLLW, SRLW, SRAW,
    ECALL,
    EBREAK,
    SRET,
    MRET,
    WFI,
    SFENCE_VMA,
    CSRRW, CSRRS, CSRRC,
    CSRRWI, CSRRSI, CSRRCI,
    NOP,

    // RVC (compressed)
    C_ADDI4SPN,
    C_ADDI16SP,
    C_LI,
    C_LUI,
    C_NOP,
    C_J,
    C_JR,
    C_JALR,
    C_BEQZ, C_BNEZ,
    C_ADDI, C_ADDIW,
    C_SLLI,
    C_SRLI, C_SRAI, C_ANDI,
    C_MV,
    C_ADD,
    C_SUB, C_SUBW, C_ADDW, C_XOR, C_OR, C_AND,
    C_LW, C_LD, C_LWSP, C_LDSP,
    C_SW, C_SD, C_SWSP, C_SDSP,

    // RV64F / RV64D (floating point)
    FLW, FLD, FSW, FSD,
    C_FLD, C_FSD, C_FLDSP, C_FSDSP,
    FMV_X_W, FMV_W_X, FMV_X_D, FMV_D_X,
    FSGNJ_S, FSGNJN_S, FSGNJX_S,
    FSGNJ_D, FSGNJN_D, FSGNJX_D,
    FADD_S, FSUB_S, FMUL_S, FDIV_S,
    FADD_D, FSUB_D, FMUL_D, FDIV_D,
    FEQ_S, FLT_S, FLE_S,
    FEQ_D, FLT_D, FLE_D,
    FCVT_S_D, FCVT_D_S,
    FCVT_W_S, FCVT_WU_S, FCVT_L_S, FCVT_LU_S,
    FCVT_W_D, FCVT_WU_D, FCVT_L_D, FCVT_LU_D,
    FCVT_S_W, FCVT_S_WU, FCVT_S_L, FCVT_S_LU,
    FCVT_D_W, FCVT_D_WU, FCVT_D_L, FCVT_D_LU,
}

InstrOperands :: struct {
    rd:      u8,
    rs1:     u8,
    rs2:     u8,
    rs1_val: u64,
    rs2_val: u64,
    imm:     i64,
}

Instr :: struct {
    mnemonic:      InstrMnemonic,
    is_compressed: bool,
    length:        u8,
    addr:          u64,
    raw:           u32,
    op:            InstrOperands,
}

emu_make :: proc(max_memory: int) -> Emu64 {
    e := Emu64 {
        page_table = emu_make_page_table(PAGE_SIZE),
        host_functions = make(map[string]HostFunction),
        csr = make(map[u16]u64),
        image_cache = make(map[string][]u8),
        mode = .Supervisor,
    }

    e.display = Display {
        width  = DISPLAY_WIDTH,
        height = DISPLAY_HEIGHT,
        pixels = make([]u8, DISPLAY_WIDTH*DISPLAY_HEIGHT*DISPLAY_BYTES_PER_PIXEL),
    }

    backing := make([]u8, max_memory)
    mem.arena_init(&e.page_arena, backing)

    return e
}

emu_reset :: proc(e: ^Emu64, max_memory: int) {
    delete(e.page_table.pages)
    delete(e.host_functions)
    delete(e.csr)
    delete(e.image_cache)
    delete(e.page_arena.data)

    e^ = emu_make(max_memory)
}

emu_make_page_table :: proc(page_size: u64, allocator := context.allocator) -> EmuPageTable {
    assert(page_size%16 == 0)

    return EmuPageTable {
        page_size = page_size,
        pages = make(map[u64]EmuMemoryPage, allocator),
    }
}

// Where the SBI image calls look for application images. An image is named, not
// pathed: `counter` resolves to apps/bin/counter.elf.
IMAGE_DIR :: "apps/bin"

// Serve an application image to the guest kernel, which has no filesystem of its
// own. The name must be a bare image name so a guest cannot reach anything
// outside IMAGE_DIR. Bytes stay cached for the life of the machine.
emu_image_bytes :: proc(e: ^Emu64, name: string) -> (image: []u8, ok: bool) {
    if cached, hit := e.image_cache[name]; hit {
        return cached, true
    }

    if len(name) == 0 || strings.contains_any(name, "/\\.") {
        fmt.eprintf("\nSBI image name is not a bare image name: '%v'\n\n", name)
        return nil, false
    }

    path := fmt.tprintf("%v/%v.elf", IMAGE_DIR, name)
    content, read_error := os.read_entire_file_from_path(path, context.allocator)
    if read_error != nil {
        fmt.eprintf("\nSBI cannot read image %v\n\n", path)
        return nil, false
    }

    // The name came out of guest memory into temporary storage, so the cache
    // needs its own copy to key on.
    e.image_cache[strings.clone(name)] = content
    return content, true
}

// Read a string out of guest memory, through the guest's own translation.
emu_read_string :: proc(e: ^Emu64, addr: u64, length: u64) -> string {
    buf := make([]u8, length, allocator = context.temp_allocator)
    for i in 0..<length {
        buf[i] = emu_read_u8(e, addr+i)
    }
    return string(buf)
}

emu_load_elf :: proc(e: ^Emu64, file_path: string) -> (start_addr: u64, ok: bool) {
    content, read_error := os.read_entire_file_from_path(file_path, context.allocator)
    if read_error != nil {
        // PRINT fmt.println("error reading ELF:", read_error)
        return
    }

    // Assuming little endian with all loads
    e_phoff_loc     :: 0x20
    e_phnum_loc     :: 0x38
    e_phentsize_loc :: 0x36
    e_entry_loc     :: 0x18

    header_loc := (transmute(^u64)(&content[e_phoff_loc]))^
    num_entries := u64((transmute(^u16)(&content[e_phnum_loc]))^)
    entry_size := u64((transmute(^u16)(&content[e_phentsize_loc]))^)
    entry_point_addr := u64((transmute(^u64)(&content[e_entry_loc]))^)

    // PRINT fmt.printf("header_loc: 0x%x\n", header_loc)
    // PRINT fmt.printf("num entries: %d\n", num_entries)
    // PRINT fmt.printf("entry size: 0x%x\n", entry_size)
    // PRINT fmt.printf("entry point: 0x%x\n", entry_point_addr)

    p_type_loc   :: 0x00
    p_offset_loc :: 0x08

    p_vaddr_loc  :: 0x10
    p_paddr_loc  :: 0x18

    p_filesz_loc :: 0x20
    p_memsz_loc  :: 0x28

    for i in 0..<num_entries {
        offset := header_loc + i*entry_size

        p_type := u64((transmute(^u32)(&content[offset + p_type_loc]))^)
        p_offset := u64((transmute(^u32)(&content[offset + p_offset_loc]))^)

        p_vaddr := (transmute(^u64)(&content[offset + p_vaddr_loc]))^
        p_paddr := (transmute(^u64)(&content[offset + p_paddr_loc]))^

        p_filesz := (transmute(^u64)(&content[offset + p_filesz_loc]))^
        p_memsz := (transmute(^u64)(&content[offset + p_memsz_loc]))^

        // PRINT fmt.printf("p_type: 0x%x\n", p_type)
        // PRINT fmt.printf("p_offset: 0x%x\n", p_offset)
        // PRINT fmt.printf("p_vaddr: 0x%x\n", p_vaddr)
        // PRINT fmt.printf("p_paddr: 0x%x\n", p_paddr)
        // PRINT fmt.printf("p_filesz: 0x%x\n", p_filesz)
        // PRINT fmt.printf("p_memsz: 0x%x\n", p_memsz)
        // PRINT fmt.println("--")

        if p_type == 0x01 {
           emu_copy_into_mem(e, content[p_offset:p_offset+p_filesz], p_vaddr)
        }
    }

    return entry_point_addr, true
}

emu_copy_into_mem :: proc(e: ^Emu64, src: []u8, dst_addr: u64) {
    // TODO: do this more efficiently

    for i in 0..<u64(len(src)) {
        emu_write_u8(e, dst_addr+i, src[i])
    }
}

// --- Physical memory -----------------------------------------------------------
//
// Sparse RAM addressed by physical address. A frame springs into existence the
// first time it is touched, which models a machine whose memory is simply there.
// Nothing here consults the page tables -- that is the translation layer's job,
// and a page-table walk itself reads through these.

phys_read_u64 :: proc(e: ^Emu64, paddr: u64, loc := #caller_location) -> u64 {
    page := emu_get_page(e, paddr)
    assert(page != nil, "no page found")

    offset := paddr - page.start_addr
    assert(offset+7 < u64(len(page.virtual_mem)), "u64 crosses page boundary", loc)

    return u64((transmute(^u64)(&page.virtual_mem[offset]))^)
}

phys_read_u32 :: proc(e: ^Emu64, paddr: u64, loc := #caller_location) -> u32 {
    page := emu_get_page(e, paddr)
    assert(page != nil, "no page found")

    offset := paddr - page.start_addr
    assert(offset+3 < u64(len(page.virtual_mem)), "u32 crosses page boundary", loc)

    return u32((transmute(^u32)(&page.virtual_mem[offset]))^)
}

phys_read_u16 :: proc(e: ^Emu64, paddr: u64, loc := #caller_location) -> u16 {
    page := emu_get_page(e, paddr)
    assert(page != nil, "no page found")

    offset := paddr - page.start_addr
    assert(offset+1 < u64(len(page.virtual_mem)), "u16 crosses page boundary", loc)

    return u16((transmute(^u16)(&page.virtual_mem[offset]))^)
}

phys_read_u8 :: proc(e: ^Emu64, paddr: u64, loc := #caller_location) -> u8 {
    page := emu_get_page(e, paddr)
    assert(page != nil, "no page found")

    offset := paddr - page.start_addr

    return u8((transmute(^u8)(&page.virtual_mem[offset]))^)
}

phys_write_u64 :: proc(e: ^Emu64, paddr: u64, value: u64) {
    page := emu_get_page(e, paddr)
    assert(page != nil, "no page found")

    offset := paddr - page.start_addr
    assert(offset+7 < u64(len(page.virtual_mem)), "u64 crosses page boundary")

    for i in 0..<8 {
        page.virtual_mem[int(offset)+i] = u8((value>>(uint(i)*8))&0xFF)
    }
}

phys_write_u32 :: proc(e: ^Emu64, paddr: u64, value: u32) {
    page := emu_get_page(e, paddr)
    assert(page != nil, "no page found")

    offset := paddr - page.start_addr
    assert(offset+3 < u64(len(page.virtual_mem)), "u32 crosses page boundary")

    for i in 0..<4 {
        page.virtual_mem[int(offset)+i] = u8((value>>(uint(i)*8))&0xFF)
    }
}

phys_write_u16 :: proc(e: ^Emu64, paddr: u64, value: u16) {
    page := emu_get_page(e, paddr)
    assert(page != nil, "no page found")

    offset := paddr - page.start_addr
    assert(offset+1 < u64(len(page.virtual_mem)), "u16 crosses page boundary")

    for i in 0..<2 {
        page.virtual_mem[int(offset)+i] = u8((value>>(uint(i)*8))&0xFF)
    }
}

phys_write_u8 :: proc(e: ^Emu64, paddr: u64, value: u8) {
    page := emu_get_page(e, paddr)
    assert(page != nil, "no page found")

    offset := paddr - page.start_addr
    page.virtual_mem[offset] = value
}

// --- Address translation -------------------------------------------------------

// Turn a virtual address into a physical one under the current satp. With paging
// off, or in machine mode, the address passes through untouched -- which is what
// lets the host load ELF images before the kernel has built any page tables.
//
// A failed walk records a fault and returns 0; the access still completes against
// physical page 0 and emu_step delivers the trap immediately afterwards.
emu_translate :: proc(e: ^Emu64, vaddr: u64, access: MemAccess) -> u64 {
    satp := emu_read_csr(e, CSR_SATP)
    if (satp >> 60) != SATP_MODE_SV39 do return vaddr
    if e.mode == .Machine do return vaddr

    vpn := [3]u64{
        (vaddr >> 12) & 0x1FF,
        (vaddr >> 21) & 0x1FF,
        (vaddr >> 30) & 0x1FF,
    }

    fault :: proc(e: ^Emu64, vaddr: u64, access: MemAccess) -> u64 {
        e.fault_pending = true
        e.fault_addr = vaddr
        switch access {
            case .Fetch: e.fault_cause = CAUSE_FETCH_PAGE_FAULT
            case .Load:  e.fault_cause = CAUSE_LOAD_PAGE_FAULT
            case .Store: e.fault_cause = CAUSE_STORE_PAGE_FAULT
        }
        return 0
    }

    table := (satp & 0xFFF_FFFF_FFFF) << PAGE_SHIFT

    for level := 2; level >= 0; level -= 1 {
        pte := phys_read_u64(e, table + vpn[level]*PTE_SIZE)

        if (pte & PTE_V) == 0 do return fault(e, vaddr, access)
        // Writable-but-not-readable is a reserved encoding.
        if (pte & PTE_W) != 0 && (pte & PTE_R) == 0 do return fault(e, vaddr, access)

        if (pte & (PTE_R | PTE_X)) == 0 {
            // A pointer to the next level down.
            table = ((pte >> 10) & 0xFFF_FFFF_FFFF) << PAGE_SHIFT
            continue
        }

        // Leaf. Check that this access is one the mapping actually permits.
        switch access {
            case .Fetch: if (pte & PTE_X) == 0 do return fault(e, vaddr, access)
            case .Load:  if (pte & PTE_R) == 0 do return fault(e, vaddr, access)
            case .Store: if (pte & PTE_W) == 0 do return fault(e, vaddr, access)
        }

        // A page without U is off limits to user mode.
        if e.mode == .User && (pte & PTE_U) == 0 do return fault(e, vaddr, access)

        // The supervisor may reach into user pages only while SUM is set, and
        // then only for data: executing user code as the kernel is never allowed,
        // whatever SUM says.
        if e.mode == .Supervisor && (pte & PTE_U) != 0 {
            if access == .Fetch do return fault(e, vaddr, access)
            if (emu_read_csr(e, CSR_SSTATUS) & SSTATUS_SUM) == 0 {
                return fault(e, vaddr, access)
            }
        }

        // For a superpage the levels below the leaf come from the virtual address.
        ppn := (pte >> 10) & 0xFFF_FFFF_FFFF
        for j in 0..<level {
            shift := uint(9 * j)
            ppn = (ppn &~ (u64(0x1FF) << shift)) | (vpn[j] << shift)
        }

        return (ppn << PAGE_SHIFT) | (vaddr & (PAGE_SIZE - 1))
    }

    return fault(e, vaddr, access)
}

// --- Virtual memory ------------------------------------------------------------
// What the executing guest sees. Every access translates first.

emu_read_u64 :: proc(e: ^Emu64, vaddr: u64, loc := #caller_location) -> u64 {
    return phys_read_u64(e, emu_translate(e, vaddr, .Load), loc)
}

emu_read_u32 :: proc(e: ^Emu64, vaddr: u64, loc := #caller_location) -> u32 {
    return phys_read_u32(e, emu_translate(e, vaddr, .Load), loc)
}

emu_read_u16 :: proc(e: ^Emu64, vaddr: u64, loc := #caller_location) -> u16 {
    return phys_read_u16(e, emu_translate(e, vaddr, .Load), loc)
}

emu_read_u8 :: proc(e: ^Emu64, vaddr: u64, loc := #caller_location) -> u8 {
    return phys_read_u8(e, emu_translate(e, vaddr, .Load), loc)
}

emu_write_u64 :: proc(e: ^Emu64, vaddr: u64, value: u64) {
    phys_write_u64(e, emu_translate(e, vaddr, .Store), value)
}

emu_write_u32 :: proc(e: ^Emu64, vaddr: u64, value: u32) {
    phys_write_u32(e, emu_translate(e, vaddr, .Store), value)
}

emu_write_u16 :: proc(e: ^Emu64, vaddr: u64, value: u16) {
    phys_write_u16(e, emu_translate(e, vaddr, .Store), value)
}

emu_write_u8 :: proc(e: ^Emu64, vaddr: u64, value: u8) {
    phys_write_u8(e, emu_translate(e, vaddr, .Store), value)
}

// Instruction fetch: same translation, but it must be against an executable page.
emu_fetch_u16 :: proc(e: ^Emu64, vaddr: u64) -> u16 {
    return phys_read_u16(e, emu_translate(e, vaddr, .Fetch))
}

// The sparse physical page store. Takes a PHYSICAL address.
emu_get_page :: proc(e: ^Emu64, paddr: u64) -> ^EmuMemoryPage {
    page_index := paddr/e.page_table.page_size
    page, ok := &e.page_table.pages[page_index]
    // assert(ok, "page hasn't been created yet")
    if !ok {
        e.page_table.pages[page_index] = EmuMemoryPage {
            start_addr = e.page_table.page_size * page_index,
            virtual_mem = make([]u8, e.page_table.page_size, mem.arena_allocator(&e.page_arena)),
        }

        return &e.page_table.pages[page_index]
    }

    return page
}

// --- The display -----------------------------------------------------------------
//
// A framebuffer the guest draws into and asks to have shown. The emulator owns the
// pixels and knows nothing about how they reach a screen: the front end installs a
// `show` procedure, so the same machine renders into a terminal over ssh or into a
// window, and the guest cannot tell which.
//
// Pixels are RGBA, one byte each, row by row from the top.

DISPLAY_WIDTH :: 64
DISPLAY_HEIGHT :: 64
DISPLAY_BYTES_PER_PIXEL :: 4

Display :: struct {
    width, height: int,
    pixels:        []u8,
    show:          proc(width, height: int, pixels: []u8),
}

EmuValue :: union {
    u32,
    u64
}

EmuArgU32    :: u32
EmuArgU64    :: u64

// Point the machine at a bootloader entry and prepare it to run once: set pc to
// the entry, install the power-off vector in ra so a top-level `ret` halts the
// machine, and set sp to the top of the guest stack. Swap the entry to boot a
// different image.
emu_boot :: proc(e: ^Emu64, entry: u64, stack_top: u64 = EMU_STACK_TOP) {
    e.pc = entry
    emu_write_reg(e, REG_RA, EMU_HALT_VECTOR)
    emu_write_reg(e, REG_X2, stack_top)

    // The boot image is the kernel, so it starts in supervisor mode.
    e.mode = .Supervisor
}

emu_comm_stack_clear :: proc(e: ^Emu64) {
    e.comm_stack_num = 0
}

emu_comm_stack_push :: proc(e: ^Emu64, arg: EmuValue, loc := #caller_location) {
    assert(e.comm_stack_num < len(e.comm_stack), "too much stack", loc)
    e.comm_stack[e.comm_stack_num] = arg
    e.comm_stack_num += 1
}

// FIXME: actually allow pushing u8s
emu_comm_stack_pop_u8 :: proc(e: ^Emu64) -> (value: u8, ok: bool) {
    emu_value := emu_comm_stack_pop(e) or_return

    #partial switch v in emu_value {
        case EmuArgU32: {
            return u8(v), true
        }
    }

    return
}

emu_comm_stack_pop_u32 :: proc(e: ^Emu64) -> (value: u32, ok: bool) {
    emu_value := emu_comm_stack_pop(e) or_return

    #partial switch v in emu_value {
        case EmuArgU32: {
            return u32(v), true
        }
    }

    return
}

emu_comm_stack_pop_u64 :: proc(e: ^Emu64) -> (value: u64, ok: bool) {
    emu_value := emu_comm_stack_pop(e) or_return

    #partial switch v in emu_value {
        case EmuArgU64: {
            return u64(v), true
        }
    }

    return
}

emu_comm_stack_pop_string :: proc(e: ^Emu64, allocator := context.allocator) -> (value: string, ok: bool) {
    addr := emu_comm_stack_pop_u64(e) or_return
    len := emu_comm_stack_pop_u32(e) or_return

    buf := make([]u8, len)
    for i in 0..<len {
        buf[i] = emu_read_u8(e, addr+u64(i))
    }
    return string(buf), true
}

emu_comm_stack_pop :: proc(e: ^Emu64) -> (value: EmuValue, ok: bool) {
    if e.comm_stack_num > 0 {
        value = e.comm_stack[e.comm_stack_num-1]
        e.comm_stack_num -= 1

        return value, true
    } else {
        return
    }
}

emu_add_host_function :: proc(e: ^Emu64, func_name: string, user_data: rawptr, fn: HostFn) {
    e.host_functions[func_name] = HostFunction {
        fn = fn,
        user_data = user_data,
    }
}

emu_decode_instr :: proc(e: ^Emu64, addr: u64 = 0) -> Instr {
    addr := e.pc if addr == 0 else addr

    instruction_lo := emu_fetch_u16(e, addr)
    prefix := instruction_lo & 0b11

    result := Instr{
        addr = addr,
    }

    switch prefix {
        case 0b00: decode_rvc_q0(e, instruction_lo, &result)
        case 0b01: decode_rvc_q1(e, instruction_lo, &result)
        case 0b10: decode_rvc_q2(e, instruction_lo, &result)
        case 0b11: decode_rv64(e, addr, &result)
    }

    return result
}

abi_name :: proc(reg: u8) -> string {
    @(static) names := [32]string {
        "zero", "ra", "sp", "gp", "tp",
        "t0", "t1", "t2",
        "s0", "s1",
        "a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7",
        "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11",
        "t3", "t4", "t5", "t6",
    }
    if reg < 32 {
        return names[reg]
    }
    return "?"
}

mnemonic_text :: proc(m: InstrMnemonic, allocator := context.temp_allocator) -> string {
    name := fmt.tprintf("%v", m)
    b := strings.builder_make(allocator)
    for c in name {
        if c == '_' {
            strings.write_byte(&b, '.')
        } else if c >= 'A' && c <= 'Z' {
            strings.write_byte(&b, byte(c) + 32)
        } else {
            strings.write_rune(&b, c)
        }
    }
    return strings.to_string(b)
}

emu_disasm :: proc(e: ^Emu64, addr: u64, allocator := context.temp_allocator) -> (line: string, length: u8) {
    saved_pc := e.pc
    e.pc = addr
    instr := emu_decode_instr(e, addr)
    e.pc = saved_pc

    length = instr.length

    b := strings.builder_make(allocator)

    // Append "  ; -> 0xADDR" for a resolved branch/jump target.
    write_target :: proc(b: ^strings.Builder, target: u64) {
        fmt.sbprintf(b, "  ; -> 0x%x", target)
    }

    if instr.is_compressed {
        fmt.sbprintf(&b, "0x%016x: %04x      ", addr, u16(instr.raw))
    } else {
        fmt.sbprintf(&b, "0x%016x: %08x  ", addr, instr.raw)
    }

    mnem := mnemonic_text(instr.mnemonic, allocator)
    op := instr.op

    switch instr.mnemonic {
        case .INVALID:
            fmt.sbprintf(&b, "invalid")
        case .NOP, .C_NOP:
            fmt.sbprintf(&b, "nop")
        case .ECALL:
            fmt.sbprintf(&b, "ecall")
        case .EBREAK:
            fmt.sbprintf(&b, "ebreak")
        case .SRET:
            fmt.sbprintf(&b, "sret")
        case .MRET:
            fmt.sbprintf(&b, "mret")
        case .WFI:
            fmt.sbprintf(&b, "wfi")
        case .SFENCE_VMA:
            fmt.sbprintf(&b, "sfence.vma")

        case .CSRRW, .CSRRS, .CSRRC:
            fmt.sbprintf(&b, "%s %s, 0x%x, %s", mnem, abi_name(op.rd), u64(op.imm), abi_name(op.rs1))
        case .CSRRWI, .CSRRSI, .CSRRCI:
            fmt.sbprintf(&b, "%s %s, 0x%x, %d", mnem, abi_name(op.rd), u64(op.imm), op.rs1)

        case .ADD, .SUB, .SLL, .SLT, .SLTU, .XOR, .SRL, .SRA, .OR, .AND,
             .MUL, .MULH, .MULHSU, .MULHU, .DIV, .DIVU, .REM, .REMU,
             .ADDW, .SUBW, .MULW, .SLLW, .SRLW, .SRAW,
             .C_ADD, .C_SUB, .C_SUBW, .C_ADDW, .C_XOR, .C_OR, .C_AND, .C_MV:
            fmt.sbprintf(&b, "%s %s, %s, %s", mnem, abi_name(op.rd), abi_name(op.rs1), abi_name(op.rs2))

        case .ADDI, .SLTI, .SLTIU, .XORI, .ORI, .ANDI, .SLLI, .SRLI, .SRAI,
             .ADDIW, .SLLIW, .SRLIW, .SRAIW,
             .C_ADDI, .C_ADDIW, .C_SLLI, .C_SRLI, .C_SRAI, .C_ANDI,
             .C_ADDI4SPN, .C_ADDI16SP, .C_LI:
            fmt.sbprintf(&b, "%s %s, %s, %d", mnem, abi_name(op.rd), abi_name(op.rs1), op.imm)

        case .LUI, .AUIPC, .C_LUI:
            fmt.sbprintf(&b, "%s %s, 0x%x", mnem, abi_name(op.rd), u64(op.imm))

        case .LB, .LH, .LW, .LD, .LBU, .LHU, .LWU,
             .C_LW, .C_LD, .C_LWSP, .C_LDSP:
            fmt.sbprintf(&b, "%s %s, %d(%s)", mnem, abi_name(op.rd), op.imm, abi_name(op.rs1))

        case .JALR:
            fmt.sbprintf(&b, "%s %s, %d(%s)", mnem, abi_name(op.rd), op.imm, abi_name(op.rs1))
            // Indirect target depends on rs1's live value, so only annotate the
            // instruction about to execute.
            if addr == saved_pc {
                target := u64(i64(op.rs1_val) + op.imm) & ~u64(1)
                write_target(&b, target)
            }

        case .SB, .SH, .SW, .SD, .C_SW, .C_SD, .C_SWSP, .C_SDSP:
            fmt.sbprintf(&b, "%s %s, %d(%s)", mnem, abi_name(op.rs2), op.imm, abi_name(op.rs1))

        case .BEQ, .BNE, .BLT, .BGE, .BLTU, .BGEU:
            target := u64(i64(addr) + op.imm)
            fmt.sbprintf(&b, "%s %s, %s, 0x%x", mnem, abi_name(op.rs1), abi_name(op.rs2), target)
            write_target(&b, target)

        case .C_BEQZ, .C_BNEZ:
            target := u64(i64(addr) + op.imm)
            fmt.sbprintf(&b, "%s %s, 0x%x", mnem, abi_name(op.rs1), target)
            write_target(&b, target)

        case .JAL:
            target := u64(i64(addr) + op.imm)
            fmt.sbprintf(&b, "%s %s, 0x%x", mnem, abi_name(op.rd), target)
            write_target(&b, target)

        case .C_J:
            target := u64(i64(addr) + op.imm)
            fmt.sbprintf(&b, "%s 0x%x", mnem, target)
            write_target(&b, target)

        case .C_JR, .C_JALR:
            fmt.sbprintf(&b, "%s %s", mnem, abi_name(op.rs1))
            // Indirect target depends on rs1's live value, so only annotate the
            // instruction about to execute.
            if addr == saved_pc {
                write_target(&b, op.rs1_val)
            }

        case .FLW, .FLD, .C_FLD, .C_FLDSP:
            fmt.sbprintf(&b, "%s f%d, %d(%s)", mnem, op.rd, op.imm, abi_name(op.rs1))
        case .FSW, .FSD, .C_FSD, .C_FSDSP:
            fmt.sbprintf(&b, "%s f%d, %d(%s)", mnem, op.rs2, op.imm, abi_name(op.rs1))
        case .FMV_X_W, .FMV_X_D, .FMV_W_X, .FMV_D_X,
             .FSGNJ_S, .FSGNJN_S, .FSGNJX_S, .FSGNJ_D, .FSGNJN_D, .FSGNJX_D,
             .FADD_S, .FSUB_S, .FMUL_S, .FDIV_S, .FADD_D, .FSUB_D, .FMUL_D, .FDIV_D,
             .FEQ_S, .FLT_S, .FLE_S, .FEQ_D, .FLT_D, .FLE_D,
             .FCVT_S_D, .FCVT_D_S,
             .FCVT_W_S, .FCVT_WU_S, .FCVT_L_S, .FCVT_LU_S,
             .FCVT_W_D, .FCVT_WU_D, .FCVT_L_D, .FCVT_LU_D,
             .FCVT_S_W, .FCVT_S_WU, .FCVT_S_L, .FCVT_S_LU,
             .FCVT_D_W, .FCVT_D_WU, .FCVT_D_L, .FCVT_D_LU:
            fmt.sbprintf(&b, "%s f%d, f%d, f%d", mnem, op.rd, op.rs1, op.rs2)

        case:
            fmt.sbprintf(&b, "%s rd=%s rs1=%s rs2=%s imm=%d", mnem, abi_name(op.rd), abi_name(op.rs1), abi_name(op.rs2), op.imm)
    }

    line = strings.to_string(b)
    return
}

// --- 32-bit instruction decoder ---

decode_rv64 :: proc(e: ^Emu64, addr: u64, result: ^Instr) {
    OP_JAL                     :: 0b1101111
    OP_JALR                    :: 0b1100111
    OP_LUI                     :: 0b0110111
    OP_AUIPC                   :: 0b0010111
    OP_ARITHMETIC_GROUP        :: 0b0110011
    OP_ARITHMETIC_64_GROUP     :: 0b0011011
    OP_ARITHMETIC_64_REG_GROUP :: 0b0111011
    OP_BRANCH_GROUP            :: 0b1100011
    OP_STORE_GROUP             :: 0b0100011
    OP_LOAD_GROUP              :: 0b0000011
    OP_SIGNED_ARITHMETIC_GROUP :: 0b0010011
    OP_SYSTEM                  :: 0b1110011
    OP_LOAD_FP                  :: 0b0000111
    OP_STORE_FP                 :: 0b0100111
    OP_FP                       :: 0b1010011

    raw := u32(emu_fetch_u16(e, addr)) | (u32(emu_fetch_u16(e, addr+2)) << 16)
    instr := EmuInstruction32{ raw_instruction = raw }

    result.raw = raw
    result.length = 4
    result.is_compressed = false

    switch instr.opcode.v {
        case OP_JAL: {
            imm_32 := (u32(instr.j_type.imm_hi) << 12) | (u32(instr.j_type.imm_lo) << 1) | (u32(instr.j_type.imm_mid) << 11) | (u32(instr.j_type.imm_msb) << 20)
            result.mnemonic = .JAL
            result.op.rd = instr.j_type.rd
            result.op.imm = i64(sign_extend_u32(imm_32, 21))
        }
        case OP_LUI: {
            result.mnemonic = .LUI
            result.op.rd = instr.u_type.rd
            result.op.imm = i64(i32(instr.u_type.imm << 12))
        }
        case OP_AUIPC: {
            result.mnemonic = .AUIPC
            result.op.rd = instr.u_type.rd
            result.op.imm = i64(i32(instr.u_type.imm << 12))
        }
        case OP_JALR: {
            result.mnemonic = .JALR
            result.op.rd = instr.i_type.rd
            result.op.rs1 = instr.i_type.rs1
            result.op.rs1_val = emu_read_reg(e, int(instr.i_type.rs1))
            result.op.imm = i64(sign_extend_u16(instr.i_type.imm, 12))
        }
        case OP_LOAD_GROUP: {
            decode_rv64_load(e, instr, result)
        }
        case OP_SIGNED_ARITHMETIC_GROUP: {
            decode_rv64_signed_arith(e, instr, result)
        }
        case OP_ARITHMETIC_GROUP: {
            decode_rv64_r_type(e, instr, result)
        }
        case OP_ARITHMETIC_64_GROUP: {
            decode_rv64_arith64(e, instr, result)
        }
        case OP_ARITHMETIC_64_REG_GROUP: {
            decode_rv64_arith64_reg(e, instr, result)
        }
        case OP_BRANCH_GROUP: {
            decode_rv64_branch(e, instr, result)
        }
        case OP_STORE_GROUP: {
            decode_rv64_store(e, instr, result)
        }
        case OP_SYSTEM: {
            decode_rv64_system(e, instr, result)
        }
        case OP_LOAD_FP: {
            decode_rv64_load_fp(e, instr, result)
        }
        case OP_STORE_FP: {
            decode_rv64_store_fp(e, instr, result)
        }
        case OP_FP: {
            decode_rv64_op_fp(e, instr, result)
        }
    }
}

// The SYSTEM opcode covers both the privileged instructions and the CSR ops, told
// apart by funct3: 0 selects a privileged instruction identified by the immediate,
// anything else is a CSR access with the CSR address in the immediate. Decoding
// the whole opcode as ECALL would quietly turn every csr access into a syscall.
decode_rv64_system :: proc(e: ^Emu64, instr: EmuInstruction32, result: ^Instr) {
    funct3 := instr.i_type.funct_3
    csr := instr.i_type.imm

    result.op.rd = instr.i_type.rd
    result.op.rs1 = instr.i_type.rs1
    result.op.rs1_val = emu_read_reg(e, int(instr.i_type.rs1))
    result.op.imm = i64(csr)

    switch funct3 {
        case 0b000: {
            // SFENCE.VMA carries operands in rs1/rs2, so it is identified by
            // funct7 rather than by the whole immediate.
            if instr.r_type.funct_7 == 0b0001001 {
                result.mnemonic = .SFENCE_VMA
                break
            }
            switch csr {
                case 0x000: result.mnemonic = .ECALL
                case 0x001: result.mnemonic = .EBREAK
                case 0x102: result.mnemonic = .SRET
                case 0x302: result.mnemonic = .MRET
                case 0x105: result.mnemonic = .WFI
            }
        }
        case 0b001: result.mnemonic = .CSRRW
        case 0b010: result.mnemonic = .CSRRS
        case 0b011: result.mnemonic = .CSRRC
        case 0b101: result.mnemonic = .CSRRWI
        case 0b110: result.mnemonic = .CSRRSI
        case 0b111: result.mnemonic = .CSRRCI
    }
}

decode_rv64_load_fp :: proc(e: ^Emu64, instr: EmuInstruction32, result: ^Instr) {
    result.op.rd = instr.i_type.rd
    result.op.rs1 = instr.i_type.rs1
    result.op.rs1_val = emu_read_reg(e, int(instr.i_type.rs1))
    result.op.imm = i64(sign_extend_u16(instr.i_type.imm, 12))

    switch instr.i_type.funct_3 {
        case 0b010: result.mnemonic = .FLW
        case 0b011: result.mnemonic = .FLD
    }
}

decode_rv64_store_fp :: proc(e: ^Emu64, instr: EmuInstruction32, result: ^Instr) {
    result.op.rs1 = instr.s_type.rs1
    result.op.rs2 = instr.s_type.rs2
    result.op.rs1_val = emu_read_reg(e, int(instr.s_type.rs1))
    result.op.rs2_val = emu_read_freg(e, int(instr.s_type.rs2))
    result.op.imm = i64(sign_extend_u32((u32(instr.s_type.imm_hi)<<5) | u32(instr.s_type.imm_lo), 12))

    switch instr.s_type.funct_3 {
        case 0b010: result.mnemonic = .FSW
        case 0b011: result.mnemonic = .FSD
    }
}

// OP-FP (0b1010011): funct7 selects the op family; funct3 is the rounding mode
// for arithmetic or a sub-selector for sign-inject/compare; rs2 sub-selects for
// fcvt/fmv/fclass. rs1_val/rs2_val are read from the FP file; for int<->fp moves
// and int->fp converts, rs1 is read from the integer file instead.
decode_rv64_op_fp :: proc(e: ^Emu64, instr: EmuInstruction32, result: ^Instr) {
    rd     := instr.r_type.rd
    rs1    := instr.r_type.rs1
    rs2    := instr.r_type.rs2
    funct3 := instr.r_type.funct_3
    funct7 := instr.r_type.funct_7

    result.op.rd = rd
    result.op.rs1 = rs1
    result.op.rs2 = rs2
    result.op.rs1_val = emu_read_freg(e, int(rs1))
    result.op.rs2_val = emu_read_freg(e, int(rs2))

    switch funct7 {
        case 0b0000000: result.mnemonic = .FADD_S
        case 0b0000001: result.mnemonic = .FADD_D
        case 0b0000100: result.mnemonic = .FSUB_S
        case 0b0000101: result.mnemonic = .FSUB_D
        case 0b0001000: result.mnemonic = .FMUL_S
        case 0b0001001: result.mnemonic = .FMUL_D
        case 0b0001100: result.mnemonic = .FDIV_S
        case 0b0001101: result.mnemonic = .FDIV_D
        case 0b0010000: // FSGNJ.S family
            switch funct3 {
                case 0b000: result.mnemonic = .FSGNJ_S
                case 0b001: result.mnemonic = .FSGNJN_S
                case 0b010: result.mnemonic = .FSGNJX_S
            }
        case 0b0010001: // FSGNJ.D family
            switch funct3 {
                case 0b000: result.mnemonic = .FSGNJ_D
                case 0b001: result.mnemonic = .FSGNJN_D
                case 0b010: result.mnemonic = .FSGNJX_D
            }
        case 0b0100000: result.mnemonic = .FCVT_S_D
        case 0b0100001: result.mnemonic = .FCVT_D_S
        case 0b1010000: // FCMP.S (rd is integer)
            switch funct3 {
                case 0b010: result.mnemonic = .FEQ_S
                case 0b001: result.mnemonic = .FLT_S
                case 0b000: result.mnemonic = .FLE_S
            }
        case 0b1010001: // FCMP.D (rd is integer)
            switch funct3 {
                case 0b010: result.mnemonic = .FEQ_D
                case 0b001: result.mnemonic = .FLT_D
                case 0b000: result.mnemonic = .FLE_D
            }
        case 0b1100000: // FCVT.int.S (rd integer, rs1 fp)
            switch rs2 {
                case 0b00000: result.mnemonic = .FCVT_W_S
                case 0b00001: result.mnemonic = .FCVT_WU_S
                case 0b00010: result.mnemonic = .FCVT_L_S
                case 0b00011: result.mnemonic = .FCVT_LU_S
            }
        case 0b1100001: // FCVT.int.D (rd integer, rs1 fp)
            switch rs2 {
                case 0b00000: result.mnemonic = .FCVT_W_D
                case 0b00001: result.mnemonic = .FCVT_WU_D
                case 0b00010: result.mnemonic = .FCVT_L_D
                case 0b00011: result.mnemonic = .FCVT_LU_D
            }
        case 0b1101000: // FCVT.S.int (rd fp, rs1 integer)
            result.op.rs1_val = emu_read_reg(e, int(rs1))
            switch rs2 {
                case 0b00000: result.mnemonic = .FCVT_S_W
                case 0b00001: result.mnemonic = .FCVT_S_WU
                case 0b00010: result.mnemonic = .FCVT_S_L
                case 0b00011: result.mnemonic = .FCVT_S_LU
            }
        case 0b1101001: // FCVT.D.int (rd fp, rs1 integer)
            result.op.rs1_val = emu_read_reg(e, int(rs1))
            switch rs2 {
                case 0b00000: result.mnemonic = .FCVT_D_W
                case 0b00001: result.mnemonic = .FCVT_D_WU
                case 0b00010: result.mnemonic = .FCVT_D_L
                case 0b00011: result.mnemonic = .FCVT_D_LU
            }
        case 0b1110000: // FMV.X.W / FCLASS.S (rd integer)
            if funct3 == 0b000 do result.mnemonic = .FMV_X_W
        case 0b1110001: // FMV.X.D / FCLASS.D (rd integer)
            if funct3 == 0b000 do result.mnemonic = .FMV_X_D
        case 0b1111000: // FMV.W.X (rd fp, rs1 integer)
            result.op.rs1_val = emu_read_reg(e, int(rs1))
            result.mnemonic = .FMV_W_X
        case 0b1111001: // FMV.D.X (rd fp, rs1 integer)
            result.op.rs1_val = emu_read_reg(e, int(rs1))
            result.mnemonic = .FMV_D_X
    }
}

decode_rv64_load :: proc(e: ^Emu64, instr: EmuInstruction32, result: ^Instr) {
    result.op.rd = instr.i_type.rd
    result.op.rs1 = instr.i_type.rs1
    result.op.rs1_val = emu_read_reg(e, int(instr.i_type.rs1))
    result.op.imm = i64(sign_extend_u16(instr.i_type.imm, 12))

    switch instr.i_type.funct_3 {
        case 0b000: result.mnemonic = .LB
        case 0b001: result.mnemonic = .LH
        case 0b010: result.mnemonic = .LW
        case 0b011: result.mnemonic = .LD
        case 0b100: result.mnemonic = .LBU
        case 0b101: result.mnemonic = .LHU
        case 0b110: result.mnemonic = .LWU
    }
}

decode_rv64_signed_arith :: proc(e: ^Emu64, instr: EmuInstruction32, result: ^Instr) {
    result.op.rd = instr.i_type.rd
    result.op.rs1 = instr.i_type.rs1
    result.op.rs1_val = emu_read_reg(e, int(instr.i_type.rs1))

    switch instr.i_type.funct_3 {
        case 0b000: {
            result.mnemonic = .ADDI
            result.op.imm = i64(sign_extend_u16(instr.i_type.imm, 12))
        }
        case 0b001: {
            result.mnemonic = .SLLI
            result.op.imm = i64(instr.i_type.imm & 0x3f)
        }
        case 0b010: {
            result.mnemonic = .SLTI
            result.op.imm = i64(sign_extend_u16(instr.i_type.imm, 12))
        }
        case 0b011: {
            result.mnemonic = .SLTIU
            result.op.imm = i64(sign_extend_u16(instr.i_type.imm, 12))
        }
        case 0b100: {
            result.mnemonic = .XORI
            result.op.imm = i64(sign_extend_u16(instr.i_type.imm, 12))
        }
        case 0b101: {
            if ((instr.i_type.imm >> 10) & 1) > 0 {
                result.mnemonic = .SRAI
            } else {
                result.mnemonic = .SRLI
            }
            result.op.imm = i64(instr.i_type.imm & 0x3f)
        }
        case 0b110: {
            result.mnemonic = .ORI
            result.op.imm = i64(sign_extend_u16(instr.i_type.imm, 12))
        }
        case 0b111: {
            result.mnemonic = .ANDI
            result.op.imm = i64(sign_extend_u16(instr.i_type.imm, 12))
        }
    }
}

decode_rv64_r_type :: proc(e: ^Emu64, instr: EmuInstruction32, result: ^Instr) {
    result.op.rd = instr.r_type.rd
    result.op.rs1 = instr.r_type.rs1
    result.op.rs2 = instr.r_type.rs2
    result.op.rs1_val = emu_read_reg(e, int(instr.r_type.rs1))
    result.op.rs2_val = emu_read_reg(e, int(instr.r_type.rs2))

    switch instr.r_type.funct_3 {
        case 0b000: {
            switch instr.r_type.funct_7 {
                case 0b0000000: result.mnemonic = .ADD
                case 0b0100000: result.mnemonic = .SUB
                case 0b0000001: result.mnemonic = .MUL
            }
        }
        case 0b001: {
            switch instr.r_type.funct_7 {
                case 0b0000000: result.mnemonic = .SLL
                case 0b0000001: result.mnemonic = .MULH
            }
        }
        case 0b010: {
            switch instr.r_type.funct_7 {
                case 0b0000000: result.mnemonic = .SLT
                case 0b0000001: result.mnemonic = .MULHSU
            }
        }
        case 0b011: {
            switch instr.r_type.funct_7 {
                case 0b0000000: result.mnemonic = .SLTU
                case 0b0000001: result.mnemonic = .MULHU
            }
        }
        case 0b100: {
            switch instr.r_type.funct_7 {
                case 0b0000000: result.mnemonic = .XOR
                case 0b0000001: result.mnemonic = .DIV
            }
        }
        case 0b101: {
            switch instr.r_type.funct_7 {
                case 0b0000000: result.mnemonic = .SRL
                case 0b0100000: result.mnemonic = .SRA
                case 0b0000001: result.mnemonic = .DIVU
            }
        }
        case 0b110: {
            switch instr.r_type.funct_7 {
                case 0b0000000: result.mnemonic = .OR
                case 0b0000001: result.mnemonic = .REM
            }
        }
        case 0b111: {
            switch instr.r_type.funct_7 {
                case 0b0000000: result.mnemonic = .AND
                case 0b0000001: result.mnemonic = .REMU
            }
        }
    }
}

decode_rv64_arith64 :: proc(e: ^Emu64, instr: EmuInstruction32, result: ^Instr) {
    result.op.rd = instr.i_type.rd
    result.op.rs1 = instr.i_type.rs1
    result.op.rs1_val = emu_read_reg(e, int(instr.i_type.rs1))

    switch instr.i_type.funct_3 {
        case 0b000: {
            result.mnemonic = .ADDIW
            result.op.imm = i64(sign_extend_u16(instr.i_type.imm, 12))
        }
        case 0b001: {
            result.mnemonic = .SLLIW
            result.op.imm = i64(instr.i_type.imm & 0x1f)
        }
        case 0b101: {
            if ((instr.i_type.imm >> 10) & 1) > 0 {
                result.mnemonic = .SRAIW
            } else {
                result.mnemonic = .SRLIW
            }
            result.op.imm = i64(instr.i_type.imm & 0x1f)
        }
    }
}

decode_rv64_arith64_reg :: proc(e: ^Emu64, instr: EmuInstruction32, result: ^Instr) {
    result.op.rd = instr.r_type.rd
    result.op.rs1 = instr.r_type.rs1
    result.op.rs2 = instr.r_type.rs2
    result.op.rs1_val = emu_read_reg(e, int(instr.r_type.rs1))
    result.op.rs2_val = emu_read_reg(e, int(instr.r_type.rs2))

    switch instr.r_type.funct_3 {
        case 0b000: {
            switch instr.r_type.funct_7 {
                case 0b0000000: result.mnemonic = .ADDW
                case 0b0100000: result.mnemonic = .SUBW
                case 0b0000001: result.mnemonic = .MULW
            }
        }
        case 0b001: result.mnemonic = .SLLW
        case 0b101: {
            switch instr.r_type.funct_7 {
                case 0b0000000: result.mnemonic = .SRLW
                case 0b0100000: result.mnemonic = .SRAW
            }
        }
    }
}

decode_rv64_branch :: proc(e: ^Emu64, instr: EmuInstruction32, result: ^Instr) {
    imm_lo := unscramble_imm(u32(instr.b_type.imm_lo), { 4,3,2,1,11 })
    imm_hi := unscramble_imm(u32(instr.b_type.imm_hi), { 12,10,9,8,7,6,5 })
    imm := u16(imm_hi | imm_lo)

    result.op.rs1 = instr.b_type.rs1
    result.op.rs2 = instr.b_type.rs2
    result.op.rs1_val = emu_read_reg(e, int(instr.b_type.rs1))
    result.op.rs2_val = emu_read_reg(e, int(instr.b_type.rs2))
    result.op.imm = i64(sign_extend_u16(imm, 13))

    switch instr.b_type.funct_3 {
        case 0b000: result.mnemonic = .BEQ
        case 0b001: result.mnemonic = .BNE
        case 0b100: result.mnemonic = .BLT
        case 0b101: result.mnemonic = .BGE
        case 0b110: result.mnemonic = .BLTU
        case 0b111: result.mnemonic = .BGEU
    }
}

decode_rv64_store :: proc(e: ^Emu64, instr: EmuInstruction32, result: ^Instr) {
    result.op.rs1 = instr.s_type.rs1
    result.op.rs2 = instr.s_type.rs2
    result.op.rs1_val = emu_read_reg(e, int(instr.s_type.rs1))
    result.op.rs2_val = emu_read_reg(e, int(instr.s_type.rs2))
    result.op.imm = i64(sign_extend_u32((u32(instr.s_type.imm_hi)<<5) | u32(instr.s_type.imm_lo), 12))

    switch instr.s_type.funct_3 {
        case 0b000: result.mnemonic = .SB
        case 0b001: result.mnemonic = .SH
        case 0b010: result.mnemonic = .SW
        case 0b011: result.mnemonic = .SD
    }
}

// --- Compressed instruction decoders ---

decode_rvc_q0 :: proc(e: ^Emu64, instr: u16, result: ^Instr) {
    suffix := instr >> 13
    result.is_compressed = true
    result.length = 2
    result.raw = u32(instr)

    switch suffix {
        case 0b000: {
            rd := (instr >> 2) & 0b111
            imm_scrambled := u32((instr >> 5) & 0xFF)

            if imm_scrambled == 0 { return } // INVALID, halts

            imm := u64(unscramble_imm(imm_scrambled, { 5,4,9,8,7,6,2,3 }))

            result.mnemonic = .C_ADDI4SPN
            result.op.rd = u8(rd) + 8
            result.op.rs1 = 2 // sp
            result.op.rs1_val = emu_read_reg(e, REG_X2)
            result.op.imm = i64(imm)
        }
        case 0b010: {
            rd := (instr >> 2) & 0b111
            rs1 := (instr >> 7) & 0b111

            imm_1 := (instr >> 5) & 0b11
            imm_2 := (instr >> 10) & 0b111
            imm := u64(((imm_1 & 0x1) << 6) | ((imm_1 & 0b10) << 1) | (imm_2 << 3))

            result.mnemonic = .C_LW
            result.op.rd = u8(rd) + 8
            result.op.rs1 = u8(rs1) + 8
            result.op.rs1_val = emu_read_reg_cext(e, int(rs1))
            result.op.imm = i64(imm)
        }
        case 0b011: {
            rd := (instr >> 2) & 0b111
            rs1 := (instr >> 7) & 0b111

            imm_lo := (instr >> 10) & 0b111
            imm_hi := (instr >> 5) & 0b11
            imm := u64((imm_hi << 6) | (imm_lo << 3))

            result.mnemonic = .C_LD
            result.op.rd = u8(rd) + 8
            result.op.rs1 = u8(rs1) + 8
            result.op.rs1_val = emu_read_reg_cext(e, int(rs1))
            result.op.imm = i64(imm)
        }
        case 0b100: {
            input_1 := (instr >> 2) & 0x1F
            input_2 := (instr >> 7) & 0x1F
            bit_12 := (instr & 0x1000) > 0

            if !bit_12 && input_1 == 0 {
                // C.JR
                result.mnemonic = .C_JR
                result.op.rs1 = u8(input_2)
                result.op.rs1_val = emu_read_reg(e, int(input_2))
            }
        }
        case 0b110: {
            rs1 := (instr >> 7) & 0b111
            rs2 := (instr >> 2) & 0b111
            // C.SW (CS format): offset[5:3]=instr[12:10], offset[2]=instr[6], offset[6]=instr[5]
            imm := u64(((instr << 1) & 0x40) | ((instr >> 7) & 0x38) | ((instr >> 4) & 0x4))

            result.mnemonic = .C_SW
            result.op.rs1 = u8(rs1) + 8
            result.op.rs2 = u8(rs2) + 8
            result.op.rs1_val = emu_read_reg_cext(e, int(rs1))
            result.op.rs2_val = emu_read_reg_cext(e, int(rs2))
            result.op.imm = i64(imm)
        }
        case 0b111: {
            rs1 := (instr >> 7) & 0b111
            rs2 := (instr >> 2) & 0b111
            imm := u64(((instr << 1) & 0xC0) | ((instr >> 7) & 0x38))

            result.mnemonic = .C_SD
            result.op.rs1 = u8(rs1) + 8
            result.op.rs2 = u8(rs2) + 8
            result.op.rs1_val = emu_read_reg_cext(e, int(rs1))
            result.op.rs2_val = emu_read_reg_cext(e, int(rs2))
            result.op.imm = i64(imm)
        }
        case 0b001: { // C.FLD: like C.LD but the destination is an FP register
            rd := (instr >> 2) & 0b111
            rs1 := (instr >> 7) & 0b111

            imm_lo := (instr >> 10) & 0b111
            imm_hi := (instr >> 5) & 0b11
            imm := u64((imm_hi << 6) | (imm_lo << 3))

            result.mnemonic = .C_FLD
            result.op.rd = u8(rd) + 8
            result.op.rs1 = u8(rs1) + 8
            result.op.rs1_val = emu_read_reg_cext(e, int(rs1))
            result.op.imm = i64(imm)
        }
        case 0b101: { // C.FSD: like C.SD but the source is an FP register
            rs1 := (instr >> 7) & 0b111
            rs2 := (instr >> 2) & 0b111
            imm := u64(((instr << 1) & 0xC0) | ((instr >> 7) & 0x38))

            result.mnemonic = .C_FSD
            result.op.rs1 = u8(rs1) + 8
            result.op.rs2 = u8(rs2) + 8
            result.op.rs1_val = emu_read_reg_cext(e, int(rs1))
            result.op.rs2_val = emu_read_freg_cext(e, int(rs2))
            result.op.imm = i64(imm)
        }
    }
}

decode_rvc_q1 :: proc(e: ^Emu64, instr: u16, result: ^Instr) {
    suffix := instr >> 13
    result.is_compressed = true
    result.length = 2
    result.raw = u32(instr)

    switch suffix {
        case 0b000: {
            rd := (instr >> 7) & 0x1F
            imm_lo := (instr >> 2) & 0x1F
            imm_hi := (instr >> 12) & 0b1
            imm := (imm_hi << 5) | imm_lo

            if imm == 0 && rd == 0 {
                result.mnemonic = .C_NOP
                return
            }

            result.mnemonic = .C_ADDI
            result.op.rd = u8(rd)
            result.op.rs1 = u8(rd)
            result.op.rs1_val = emu_read_reg(e, int(rd))
            result.op.imm = i64(sign_extend_u16(imm, 6))
        }
        case 0b001: {
            rd := (instr >> 7) & 0x1F
            imm_lo := (instr >> 2) & 0x1F
            imm_hi := (instr >> 12) & 0b1
            imm := (imm_hi << 5) | imm_lo

            if imm == 0 && rd == 0 {
                result.mnemonic = .C_NOP
                return
            }

            result.mnemonic = .C_ADDIW
            result.op.rd = u8(rd)
            result.op.rs1 = u8(rd)
            result.op.rs1_val = emu_read_reg(e, int(rd))
            result.op.imm = i64(sign_extend_u16(imm, 6))
        }
        case 0b010: {
            rd := (instr >> 7) & 0x1F
            if rd == 0 {
                result.mnemonic = .C_NOP
                return
            }
            imm := i64(sign_extend_u16(((instr >> 2) & 0x1F) | ((instr >> 12) & 1) << 5, 6))
            result.mnemonic = .C_LI
            result.op.rd = u8(rd)
            result.op.imm = imm
        }
        case 0b011: {
            rd := (instr >> 7) & 0x1F

            if rd == 2 {
                imm_scrambled := u32((instr >> 2) & 0x1F)
                imm_12 := u32((instr >> 12) & 0x1)
                imm := u32(unscramble_imm(imm_scrambled, { 4,6,8,7,5 }))
                imm |= (imm_12 << 9)

                if imm == 0 {
                    result.mnemonic = .C_NOP
                    return
                }

                result.mnemonic = .C_ADDI16SP
                result.op.rd = 2
                result.op.rs1 = 2
                result.op.rs1_val = emu_read_reg(e, REG_X2)
                result.op.imm = i64(sign_extend_u32(imm, 10))
            } else if rd != 0 {
                imm_1 := (instr >> 2) & 0x1F
                imm_2 := (instr >> 12) & 0x1

                imm := i64(sign_extend_u32((u32(imm_1) << 12) | (u32(imm_2) << 17), 18))

                result.mnemonic = .C_LUI
                result.op.rd = u8(rd)
                result.op.imm = imm
            }
        }
        case 0b100: {
            bit_12 := (instr & 0x1000) > 0
            funct_1 := (instr >> 5) & 0b11
            funct_2 := (instr >> 10) & 0b11

            if bit_12 && funct_2 == 0b11 {
                rs2 := (instr >> 2) & 0b111
                rd := (instr >> 7) & 0b111

                switch funct_1 {
                    case 0b00: {
                        result.mnemonic = .C_SUBW
                        result.op.rd = u8(rd) + 8
                        result.op.rs1 = u8(rd) + 8
                        result.op.rs2 = u8(rs2) + 8
                        result.op.rs1_val = emu_read_reg_cext(e, int(rd))
                        result.op.rs2_val = emu_read_reg_cext(e, int(rs2))
                    }
                    case 0b01: {
                        result.mnemonic = .C_ADDW
                        result.op.rd = u8(rd) + 8
                        result.op.rs1 = u8(rd) + 8
                        result.op.rs2 = u8(rs2) + 8
                        result.op.rs1_val = emu_read_reg_cext(e, int(rd))
                        result.op.rs2_val = emu_read_reg_cext(e, int(rs2))
                    }
                }
            } else {
                imm := (instr >> 2) & 0x1F
                rs2 := (instr >> 2) & 0b111
                rd := (instr >> 7) & 0b111

                switch funct_2 {
                    case 0b00: {
                        imm_extended := u64(imm | (((instr >> 12) & 0x1) << 5))
                        result.mnemonic = .C_SRLI
                        result.op.rd = u8(rd) + 8
                        result.op.rs1 = u8(rd) + 8
                        result.op.rs1_val = emu_read_reg_cext(e, int(rd))
                        result.op.imm = i64(imm_extended)
                    }
                    case 0b01: {
                        imm_extended := u64(imm | (((instr >> 12) & 0x1) << 5))
                        result.mnemonic = .C_SRAI
                        result.op.rd = u8(rd) + 8
                        result.op.rs1 = u8(rd) + 8
                        result.op.rs1_val = emu_read_reg_cext(e, int(rd))
                        result.op.imm = i64(imm_extended)
                    }
                    case 0b10: {
                        result.mnemonic = .C_ANDI
                        result.op.rd = u8(rd) + 8
                        result.op.rs1 = u8(rd) + 8
                        result.op.rs1_val = emu_read_reg_cext(e, int(rd))
                        result.op.imm = i64(sign_extend_u16(imm | (((instr >> 12) & 0x1) << 5), 6))
                    }
                    case 0b11: {
                        switch funct_1 {
                            case 0b00: {
                                result.mnemonic = .C_SUB
                                result.op.rd = u8(rd) + 8
                                result.op.rs1 = u8(rd) + 8
                                result.op.rs2 = u8(rs2) + 8
                                result.op.rs1_val = emu_read_reg_cext(e, int(rd))
                                result.op.rs2_val = emu_read_reg_cext(e, int(rs2))
                            }
                            case 0b01: {
                                result.mnemonic = .C_XOR
                                result.op.rd = u8(rd) + 8
                                result.op.rs1 = u8(rd) + 8
                                result.op.rs2 = u8(rs2) + 8
                                result.op.rs1_val = emu_read_reg_cext(e, int(rd))
                                result.op.rs2_val = emu_read_reg_cext(e, int(rs2))
                            }
                            case 0b10: {
                                result.mnemonic = .C_OR
                                result.op.rd = u8(rd) + 8
                                result.op.rs1 = u8(rd) + 8
                                result.op.rs2 = u8(rs2) + 8
                                result.op.rs1_val = emu_read_reg_cext(e, int(rd))
                                result.op.rs2_val = emu_read_reg_cext(e, int(rs2))
                            }
                            case 0b11: {
                                result.mnemonic = .C_AND
                                result.op.rd = u8(rd) + 8
                                result.op.rs1 = u8(rd) + 8
                                result.op.rs2 = u8(rs2) + 8
                                result.op.rs1_val = emu_read_reg_cext(e, int(rd))
                                result.op.rs2_val = emu_read_reg_cext(e, int(rs2))
                            }
                        }
                    }
                }
            }
        }
        case 0b101: {
            imm := u32((instr >> 2) & 0x7FF)
            offset := sign_extend_u32(unscramble_imm(imm, { 11,4,9,8,10,6,7,3,2,1,5 }), 12)

            result.mnemonic = .C_J
            result.op.imm = i64(offset)
        }
        case 0b110: {
            rs1 := (instr >> 7) & 0b111

            imm_lo := unscramble_imm(u32((instr >> 2) & 0x1F),   { 7,6,2,1,5 })
            imm_hi := unscramble_imm(u32((instr >> 10) & 0b111), { 8,4,3 })
            imm := imm_hi | imm_lo
            offset := sign_extend_u32(imm, 9)

            result.mnemonic = .C_BEQZ
            result.op.rs1 = u8(rs1) + 8
            result.op.rs1_val = emu_read_reg_cext(e, int(rs1))
            result.op.imm = i64(offset)
        }
        case 0b111: {
            rs1 := (instr >> 7) & 0b111

            imm_lo := unscramble_imm(u32((instr >> 2) & 0x1F),   { 7,6,2,1,5 })
            imm_hi := unscramble_imm(u32((instr >> 10) & 0b111), { 8,4,3 })
            imm := imm_hi | imm_lo
            offset := sign_extend_u32(imm, 9)

            result.mnemonic = .C_BNEZ
            result.op.rs1 = u8(rs1) + 8
            result.op.rs1_val = emu_read_reg_cext(e, int(rs1))
            result.op.imm = i64(offset)
        }
    }
}

decode_rvc_q2 :: proc(e: ^Emu64, instr: u16, result: ^Instr) {
    suffix := instr >> 13
    result.is_compressed = true
    result.length = 2
    result.raw = u32(instr)

    switch suffix {
        case 0b000: {
            rd := (instr >> 7) & 0x1F
            imm := u64((instr >> 2) & 0x1F | (((instr >> 12) & 0b1) << 5))

            if rd == 0 {
                result.mnemonic = .C_NOP
                return
            }

            result.mnemonic = .C_SLLI
            result.op.rd = u8(rd)
            result.op.rs1 = u8(rd)
            result.op.rs1_val = emu_read_reg(e, int(rd))
            result.op.imm = i64(imm)
        }
        case 0b010: {
            rd := (instr >> 7) & 0x1F
            imm_1 := u32((instr >> 2) & 0x1F)
            imm_2 := u32((instr >> 12) & 0x1)

            if rd == 0 {
                result.mnemonic = .C_NOP
                return
            }

            imm := u64(unscramble_imm(imm_1, { 4,3,2,7,6 }))
            imm |= u64(imm_2) << 5

            result.mnemonic = .C_LWSP
            result.op.rd = u8(rd)
            result.op.rs1 = 2
            result.op.rs1_val = emu_read_reg(e, REG_X2)
            result.op.imm = i64(imm)
        }
        case 0b011: {
            rd := (instr >> 7) & 0x1F
            imm_1 := u32((instr >> 2) & 0x1F)
            imm_2 := u32((instr >> 12) & 0x1)

            if rd == 0 {
                result.mnemonic = .C_NOP
                return
            }

            imm := u64(unscramble_imm(imm_1, { 4,3,8,7,6 }))
            imm |= u64(imm_2) << 5

            result.mnemonic = .C_LDSP
            result.op.rd = u8(rd)
            result.op.rs1 = 2
            result.op.rs1_val = emu_read_reg(e, REG_X2)
            result.op.imm = i64(imm)
        }
        case 0b100: {
            input_1 := (instr >> 2) & 0x1F
            input_2 := (instr >> 7) & 0x1F
            bit_12 := (instr & 0x1000) > 0

            if bit_12 {
                if input_2 != 0 {
                    if input_1 == 0 {
                        // C.JALR
                        result.mnemonic = .C_JALR
                        result.op.rd = 1 // ra
                        result.op.rs1 = u8(input_2)
                        result.op.rs1_val = emu_read_reg(e, int(input_2))
                    } else {
                        // C.ADD
                        result.mnemonic = .C_ADD
                        result.op.rd = u8(input_2)
                        result.op.rs1 = u8(input_2)
                        result.op.rs2 = u8(input_1)
                        result.op.rs1_val = emu_read_reg(e, int(input_2))
                        result.op.rs2_val = emu_read_reg(e, int(input_1))
                    }
                }
            } else {
                if input_1 == 0 {
                    // C.JR
                    result.mnemonic = .C_JR
                    result.op.rs1 = u8(input_2)
                    result.op.rs1_val = emu_read_reg(e, int(input_2))
                } else if input_1 != 0 && input_2 != 0 {
                    // C.MV
                    result.mnemonic = .C_MV
                    result.op.rd = u8(input_2)
                    result.op.rs1 = u8(input_1)
                    result.op.rs1_val = emu_read_reg(e, int(input_1))
                }
            }
        }
        case 0b110: {
            rs2 := (instr >> 2) & 0x1F
            imm_1 := u32((instr >> 7) & 0x3F)
            imm := u64(unscramble_imm(imm_1, { 5,4,3,2,7,6 }))

            result.mnemonic = .C_SWSP
            result.op.rs1 = 2
            result.op.rs2 = u8(rs2)
            result.op.rs1_val = emu_read_reg(e, REG_X2)
            result.op.rs2_val = emu_read_reg(e, int(rs2))
            result.op.imm = i64(imm)
        }
        case 0b111: {
            rs2 := (instr >> 2) & 0x1F
            imm_1 := u32((instr >> 7) & 0x3F)
            imm := u64(unscramble_imm(imm_1, { 5,4,3,8,7,6 }))

            result.mnemonic = .C_SDSP
            result.op.rs1 = 2
            result.op.rs2 = u8(rs2)
            result.op.rs1_val = emu_read_reg(e, REG_X2)
            result.op.rs2_val = emu_read_reg(e, int(rs2))
            result.op.imm = i64(imm)
        }
        case 0b001: { // C.FLDSP: like C.LDSP but the destination is an FP register
            rd := (instr >> 7) & 0x1F
            imm_1 := u32((instr >> 2) & 0x1F)
            imm_2 := u32((instr >> 12) & 0x1)

            imm := u64(unscramble_imm(imm_1, { 4,3,8,7,6 }))
            imm |= u64(imm_2) << 5

            result.mnemonic = .C_FLDSP
            result.op.rd = u8(rd)
            result.op.rs1 = 2
            result.op.rs1_val = emu_read_reg(e, REG_X2)
            result.op.imm = i64(imm)
        }
        case 0b101: { // C.FSDSP: like C.SDSP but the source is an FP register
            rs2 := (instr >> 2) & 0x1F
            imm_1 := u32((instr >> 7) & 0x3F)
            imm := u64(unscramble_imm(imm_1, { 5,4,3,8,7,6 }))

            result.mnemonic = .C_FSDSP
            result.op.rs1 = 2
            result.op.rs2 = u8(rs2)
            result.op.rs1_val = emu_read_reg(e, REG_X2)
            result.op.rs2_val = emu_read_freg(e, int(rs2))
            result.op.imm = i64(imm)
        }
    }
}

// --- Instruction evaluator ---

emu_eval_instr :: proc(e: ^Emu64, di: Instr) -> (pc_offset: u64, cont: bool) {
    #partial switch di.mnemonic {
        // --- Jumps ---
        case .C_J:    fallthrough
        case .JAL: {
            emu_write_reg(e, int(di.op.rd), di.addr + u64(di.length))
            return emu_instr_jump_rel(e, i32(di.op.imm))
        }
        case .C_JALR: fallthrough
        case .JALR: {
            addr := u64(i64(di.op.rs1_val) + di.op.imm) & (~u64(1))
            emu_write_reg(e, int(di.op.rd), di.addr + u64(di.length))
            return emu_instr_jump(e, addr)
        }
        case .C_JR: {
            return emu_instr_jump(e, di.op.rs1_val)
        }

        // --- Upper immediate ---
        case .C_LUI: fallthrough
        case .LUI: {
            emu_write_reg(e, int(di.op.rd), u64(di.op.imm))
            return u64(di.length), true
        }
        case .AUIPC: {
            result: u64
            if di.op.imm > 0 {
                result = di.addr + u64(di.op.imm)
            } else {
                result = di.addr - u64(-di.op.imm)
            }
            emu_write_reg(e, int(di.op.rd), result)
            return u64(di.length), true
        }

        // --- Loads ---
        case .LB: {
            addr := u64(i64(di.op.rs1_val) + di.op.imm)
            emu_write_reg(e, int(di.op.rd), u64(i64(i8(emu_read_u8(e, addr)))))
            return u64(di.length), true
        }
        case .LH: {
            addr := u64(i64(di.op.rs1_val) + di.op.imm)
            emu_write_reg(e, int(di.op.rd), u64(i64(i16(emu_read_u16(e, addr)))))
            return u64(di.length), true
        }
        case .C_LW, .C_LWSP: fallthrough
        case .LW: {
            addr := u64(i64(di.op.rs1_val) + di.op.imm)
            emu_write_reg(e, int(di.op.rd), u64(i64(i32(emu_read_u32(e, addr)))))
            return u64(di.length), true
        }
        case .C_LD, .C_LDSP: fallthrough
        case .LD: {
            addr := u64(i64(di.op.rs1_val) + di.op.imm)
            emu_write_reg(e, int(di.op.rd), emu_read_u64(e, addr))
            return u64(di.length), true
        }
        case .LBU: {
            addr := u64(i64(di.op.rs1_val) + di.op.imm)
            emu_write_reg(e, int(di.op.rd), u64(emu_read_u8(e, addr)))
            return u64(di.length), true
        }
        case .LHU: {
            addr := u64(i64(di.op.rs1_val) + di.op.imm)
            emu_write_reg(e, int(di.op.rd), u64(emu_read_u16(e, addr)))
            return u64(di.length), true
        }
        case .LWU: {
            addr := u64(i64(di.op.rs1_val) + di.op.imm)
            emu_write_reg(e, int(di.op.rd), u64(emu_read_u32(e, addr)))
            return u64(di.length), true
        }

        // --- Stores ---
        case .SB: {
            addr := u64(i64(di.op.rs1_val) + di.op.imm)
            emu_write_u8(e, addr, u8(di.op.rs2_val & 0xFF))
            return u64(di.length), true
        }
        case .SH: {
            addr := u64(i64(di.op.rs1_val) + di.op.imm)
            emu_write_u16(e, addr, u16(di.op.rs2_val & 0xFFFF))
            return u64(di.length), true
        }
        case .C_SW, .C_SWSP: fallthrough
        case .SW: {
            addr := u64(i64(di.op.rs1_val) + di.op.imm)
            emu_write_u32(e, addr, u32(di.op.rs2_val & 0xFFFFFFFF))
            return u64(di.length), true
        }
        case .C_SD, .C_SDSP: fallthrough
        case .SD: {
            addr := u64(i64(di.op.rs1_val) + di.op.imm)
            emu_write_u64(e, addr, di.op.rs2_val)
            return u64(di.length), true
        }

        // --- R-Type arithmetic ---
        case .C_ADD, .C_MV: fallthrough
        case .ADD: {
            emu_write_reg(e, int(di.op.rd), di.op.rs1_val + di.op.rs2_val)
            return u64(di.length), true
        }
        case .C_SUB: fallthrough
        case .SUB: {
            emu_write_reg(e, int(di.op.rd), di.op.rs1_val - di.op.rs2_val)
            return u64(di.length), true
        }
        case .MUL: {
            emu_write_reg(e, int(di.op.rd), di.op.rs1_val * di.op.rs2_val)
            return u64(di.length), true
        }
        case .MULH: {
            res := i128(i64(di.op.rs1_val)) * i128(i64(di.op.rs2_val))
            emu_write_reg(e, int(di.op.rd), u64(u128(res) >> 64))
            return u64(di.length), true
        }
        case .MULHU: {
            res := u128(di.op.rs1_val) * u128(di.op.rs2_val)
            emu_write_reg(e, int(di.op.rd), u64(res >> 64))
            return u64(di.length), true
        }
        case .MULHSU: {
            // rs1 signed, rs2 unsigned (rs2 zero-extends into the positive i128 range)
            res := i128(i64(di.op.rs1_val)) * i128(di.op.rs2_val)
            emu_write_reg(e, int(di.op.rd), u64(u128(res) >> 64))
            return u64(di.length), true
        }
        case .XOR: {
            emu_write_reg(e, int(di.op.rd), di.op.rs1_val ~ di.op.rs2_val)
            return u64(di.length), true
        }
        case .OR: {
            emu_write_reg(e, int(di.op.rd), di.op.rs1_val | di.op.rs2_val)
            return u64(di.length), true
        }
        case .SLL: {
            emu_write_reg(e, int(di.op.rd), di.op.rs1_val << (di.op.rs2_val & 0x3f))
            return u64(di.length), true
        }
        case .SLT: {
            if i64(di.op.rs1_val) < i64(di.op.rs2_val) {
                emu_write_reg(e, int(di.op.rd), 1)
            } else {
                emu_write_reg(e, int(di.op.rd), 0)
            }
            return u64(di.length), true
        }
        case .SLTU: {
            if di.op.rs1_val < di.op.rs2_val {
                emu_write_reg(e, int(di.op.rd), 1)
            } else {
                emu_write_reg(e, int(di.op.rd), 0)
            }
            return u64(di.length), true
        }
        case .SRL: {
            emu_write_reg(e, int(di.op.rd), di.op.rs1_val >> (di.op.rs2_val & 0x3f))
            return u64(di.length), true
        }
        case .SRA: {
            emu_write_reg(e, int(di.op.rd), u64(i64(di.op.rs1_val) >> (di.op.rs2_val & 0x3f)))
            return u64(di.length), true
        }
        case .DIV: {
            // RV64M: /0 -> -1; signed overflow (MIN / -1) -> MIN.
            res: i64
            switch {
            case di.op.rs2_val == 0:
                res = -1
            case di.op.rs1_val == 0x8000000000000000 && di.op.rs2_val == 0xFFFFFFFFFFFFFFFF:
                res = i64(di.op.rs1_val)
            case:
                res = i64(di.op.rs1_val) / i64(di.op.rs2_val)
            }
            emu_write_reg(e, int(di.op.rd), u64(res))
            return u64(di.length), true
        }
        case .DIVU: {
            // RV64M: /0 -> all ones.
            res: u64 = 0xFFFFFFFFFFFFFFFF
            if di.op.rs2_val != 0 {
                res = di.op.rs1_val / di.op.rs2_val
            }
            emu_write_reg(e, int(di.op.rd), res)
            return u64(di.length), true
        }
        case .C_AND: fallthrough
        case .AND: {
            emu_write_reg(e, int(di.op.rd), di.op.rs1_val & di.op.rs2_val)
            return u64(di.length), true
        }
        case .REM: {
            // RV64M: rem by 0 -> dividend; signed overflow (MIN % -1) -> 0.
            // Uses truncated remainder (sign follows the dividend), i.e. Odin's %.
            res: i64
            switch {
            case di.op.rs2_val == 0:
                res = i64(di.op.rs1_val)
            case di.op.rs1_val == 0x8000000000000000 && di.op.rs2_val == 0xFFFFFFFFFFFFFFFF:
                res = 0
            case:
                res = i64(di.op.rs1_val) % i64(di.op.rs2_val)
            }
            emu_write_reg(e, int(di.op.rd), u64(res))
            return u64(di.length), true
        }
        case .REMU: {
            // RV64M: rem by 0 -> dividend.
            res := di.op.rs1_val
            if di.op.rs2_val != 0 {
                res = di.op.rs1_val %% di.op.rs2_val
            }
            emu_write_reg(e, int(di.op.rd), res)
            return u64(di.length), true
        }
        case .C_XOR: {
            emu_write_reg(e, int(di.op.rd), di.op.rs1_val ~ di.op.rs2_val)
            return u64(di.length), true
        }
        case .C_OR: {
            emu_write_reg(e, int(di.op.rd), di.op.rs1_val | di.op.rs2_val)
            return u64(di.length), true
        }

        // --- I-Type arithmetic ---
        case .C_ADDI, .C_ADDI4SPN, .C_ADDI16SP, .C_LI: fallthrough
        case .ADDI: {
            emu_write_reg(e, int(di.op.rd), u64(i64(di.op.rs1_val) + di.op.imm))
            return u64(di.length), true
        }
        case .C_SLLI: fallthrough
        case .SLLI: {
            emu_write_reg(e, int(di.op.rd), di.op.rs1_val << u64(di.op.imm))
            return u64(di.length), true
        }
        case .SLTI: {
            if i64(di.op.rs1_val) < di.op.imm {
                emu_write_reg(e, int(di.op.rd), 1)
            } else {
                emu_write_reg(e, int(di.op.rd), 0)
            }
            return u64(di.length), true
        }
        case .SLTIU: {
            if di.op.rs1_val < u64(di.op.imm) {
                emu_write_reg(e, int(di.op.rd), 1)
            } else {
                emu_write_reg(e, int(di.op.rd), 0)
            }
            return u64(di.length), true
        }
        case .XORI: {
            emu_write_reg(e, int(di.op.rd), u64(i64(di.op.rs1_val) ~ di.op.imm))
            return u64(di.length), true
        }
        case .C_SRLI: fallthrough
        case .SRLI: {
            emu_write_reg(e, int(di.op.rd), di.op.rs1_val >> u64(di.op.imm))
            return u64(di.length), true
        }
        case .C_SRAI: fallthrough
        case .SRAI: {
            emu_write_reg(e, int(di.op.rd), u64(i64(di.op.rs1_val) >> u64(di.op.imm)))
            return u64(di.length), true
        }
        case .ORI: {
            emu_write_reg(e, int(di.op.rd), u64(i64(di.op.rs1_val) | di.op.imm))
            return u64(di.length), true
        }
        case .C_ANDI: fallthrough
        case .ANDI: {
            emu_write_reg(e, int(di.op.rd), u64(i64(di.op.rs1_val) & di.op.imm))
            return u64(di.length), true
        }

        // --- 64-bit I-Type arithmetic ---
        case .C_ADDIW: fallthrough
        case .ADDIW: {
            rs1_i32 := i32(di.op.rs1_val & 0xFFFFFFFF)
            imm_i32 := i32(di.op.imm)
            emu_write_reg(e, int(di.op.rd), u64(i64(rs1_i32 + imm_i32)))
            return u64(di.length), true
        }
        case .SLLIW: {
            rs1_i32 := i32(di.op.rs1_val & 0xFFFFFFFF)
            emu_write_reg(e, int(di.op.rd), u64(i64(rs1_i32 << u16(di.op.imm))))
            return u64(di.length), true
        }

        // --- 64-bit R-Type arithmetic ---
        case .ADDW: {
            rs1_i32 := i32(di.op.rs1_val & 0xFFFFFFFF)
            rs2_i32 := i32(di.op.rs2_val & 0xFFFFFFFF)
            emu_write_reg(e, int(di.op.rd), u64(i64(rs1_i32 + rs2_i32)))
            return u64(di.length), true
        }
        case .SUBW: {
            rs1_i32 := i32(di.op.rs1_val & 0xFFFFFFFF)
            rs2_i32 := i32(di.op.rs2_val & 0xFFFFFFFF)
            emu_write_reg(e, int(di.op.rd), u64(i64(rs1_i32 - rs2_i32)))
            return u64(di.length), true
        }
        case .MULW: {
            rs1_i32 := i32(di.op.rs1_val & 0xFFFFFFFF)
            rs2_i32 := i32(di.op.rs2_val & 0xFFFFFFFF)
            emu_write_reg(e, int(di.op.rd), u64(i64(rs1_i32 * rs2_i32)))
            return u64(di.length), true
        }
        case .SLLW: {
            // W-form shifts use only rs2[4:0]; operate on 32 bits, sign-extend.
            rs1_i32 := i32(di.op.rs1_val & 0xFFFFFFFF)
            shamt := u32(di.op.rs2_val & 0x1f)
            emu_write_reg(e, int(di.op.rd), u64(i64(rs1_i32 << shamt)))
            return u64(di.length), true
        }
        case .SRLW: {
            rs1_u32 := u32(di.op.rs1_val & 0xFFFFFFFF)
            shamt := u32(di.op.rs2_val & 0x1f)
            emu_write_reg(e, int(di.op.rd), u64(i64(i32(rs1_u32 >> shamt))))
            return u64(di.length), true
        }
        case .SRAW: {
            rs1_i32 := i32(di.op.rs1_val & 0xFFFFFFFF)
            shamt := u32(di.op.rs2_val & 0x1f)
            emu_write_reg(e, int(di.op.rd), u64(i64(rs1_i32 >> shamt)))
            return u64(di.length), true
        }
        case .SRLIW: {
            rs1_u32 := u32(di.op.rs1_val & 0xFFFFFFFF)
            emu_write_reg(e, int(di.op.rd), u64(i64(i32(rs1_u32 >> u32(di.op.imm & 0x1f)))))
            return u64(di.length), true
        }
        case .SRAIW: {
            rs1_i32 := i32(di.op.rs1_val & 0xFFFFFFFF)
            emu_write_reg(e, int(di.op.rd), u64(i64(rs1_i32 >> u32(di.op.imm & 0x1f))))
            return u64(di.length), true
        }
        case .C_SUBW: {
            rs2_val := u32(di.op.rs2_val & 0xFFFFFFFF)
            rd_val := u32(di.op.rs1_val & 0xFFFFFFFF)
            rd_val -= rs2_val
            emu_write_reg(e, int(di.op.rd), u64(i64(i32(rd_val))))
            return u64(di.length), true
        }
        case .C_ADDW: {
            rs2_val := u32(di.op.rs2_val & 0xFFFFFFFF)
            rd_val := u32(di.op.rs1_val & 0xFFFFFFFF)
            rd_val += rs2_val
            emu_write_reg(e, int(di.op.rd), u64(i64(i32(rd_val))))
            return u64(di.length), true
        }

        // --- Branches ---
        case .C_BEQZ: fallthrough
        case .BEQ: {
            if i64(di.op.rs1_val) == i64(di.op.rs2_val) {
                return emu_instr_jump_rel(e, i32(di.op.imm))
            }
            return u64(di.length), true
        }
        case .C_BNEZ: fallthrough
        case .BNE: {
            if i64(di.op.rs1_val) != i64(di.op.rs2_val) {
                return emu_instr_jump_rel(e, i32(di.op.imm))
            }
            return u64(di.length), true
        }
        case .BLT: {
            if i64(di.op.rs1_val) < i64(di.op.rs2_val) {
                return emu_instr_jump_rel(e, i32(di.op.imm))
            }
            return u64(di.length), true
        }
        case .BGE: {
            if i64(di.op.rs1_val) >= i64(di.op.rs2_val) {
                return emu_instr_jump_rel(e, i32(di.op.imm))
            }
            return u64(di.length), true
        }
        case .BLTU: {
            if di.op.rs1_val < di.op.rs2_val {
                return emu_instr_jump_rel(e, i32(di.op.imm))
            }
            return u64(di.length), true
        }
        case .BGEU: {
            if di.op.rs1_val >= di.op.rs2_val {
                return emu_instr_jump_rel(e, i32(di.op.imm))
            }
            return u64(di.length), true
        }

        // --- Privileged / CSR ---
        case .ECALL: {
            // An ecall from user mode is a syscall into the guest kernel. Only an
            // ecall the kernel itself makes leaves the machine for the host, which
            // is the SBI role.
            if e.mode == .User {
                emu_trap_to_supervisor(e, CAUSE_ECALL_FROM_U, 0, di.addr)
                return 0, true
            }
            return eval_ecall(e, di)
        }
        case .EBREAK: {
            e.stop_reason = .Trap
            fmt.eprintf("\n\nEBREAK at 0x%x\n\n", di.addr)
            return 0, false
        }
        case .SRET: {
            emu_sret(e)
            return 0, true
        }
        case .WFI: {
            // Wait for the next interrupt. Time is counted per instruction, so an
            // idle guest would otherwise spin the host to reach its own deadline;
            // moving the clock straight to it costs nothing and means the same.
            if e.timer_armed && e.ticks < e.timer_deadline {
                e.ticks = e.timer_deadline
            }
            return u64(di.length), true
        }
        case .SFENCE_VMA: {
            // Translation is walked fresh on every access, so there is no TLB to
            // invalidate and the fence has nothing to do.
            return u64(di.length), true
        }
        case .CSRRW, .CSRRS, .CSRRC, .CSRRWI, .CSRRSI, .CSRRCI: {
            return eval_csr(e, di)
        }

        // --- Floating-point loads / stores ---
        // rs1_val is the integer base; rs2_val (stores) is the FP value's bits.
        case .FLD, .C_FLD, .C_FLDSP: {
            addr := u64(i64(di.op.rs1_val) + di.op.imm)
            emu_write_freg(e, int(di.op.rd), emu_read_u64(e, addr))
            return u64(di.length), true
        }
        case .FLW: {
            addr := u64(i64(di.op.rs1_val) + di.op.imm)
            emu_write_freg(e, int(di.op.rd), nanbox_f32(emu_read_u32(e, addr)))
            return u64(di.length), true
        }
        case .FSD, .C_FSD, .C_FSDSP: {
            addr := u64(i64(di.op.rs1_val) + di.op.imm)
            emu_write_u64(e, addr, di.op.rs2_val)
            return u64(di.length), true
        }
        case .FSW: {
            addr := u64(i64(di.op.rs1_val) + di.op.imm)
            emu_write_u32(e, addr, u32(di.op.rs2_val))
            return u64(di.length), true
        }

        // --- Floating-point <-> integer register moves ---
        case .FMV_X_W: {
            emu_write_reg(e, int(di.op.rd), u64(i64(i32(u32(di.op.rs1_val)))))
            return u64(di.length), true
        }
        case .FMV_X_D: {
            emu_write_reg(e, int(di.op.rd), di.op.rs1_val)
            return u64(di.length), true
        }
        case .FMV_W_X: {
            emu_write_freg(e, int(di.op.rd), nanbox_f32(u32(di.op.rs1_val)))
            return u64(di.length), true
        }
        case .FMV_D_X: {
            emu_write_freg(e, int(di.op.rd), di.op.rs1_val)
            return u64(di.length), true
        }

        // --- Sign injection (fmv.d / fneg.d / fabs.d expand to these) ---
        case .FSGNJ_D: {
            S :: u64(0x8000_0000_0000_0000)
            emu_write_freg(e, int(di.op.rd), (di.op.rs1_val &~ S) | (di.op.rs2_val & S))
            return u64(di.length), true
        }
        case .FSGNJN_D: {
            S :: u64(0x8000_0000_0000_0000)
            emu_write_freg(e, int(di.op.rd), (di.op.rs1_val &~ S) | (~di.op.rs2_val & S))
            return u64(di.length), true
        }
        case .FSGNJX_D: {
            S :: u64(0x8000_0000_0000_0000)
            emu_write_freg(e, int(di.op.rd), di.op.rs1_val ~ (di.op.rs2_val & S))
            return u64(di.length), true
        }
        case .FSGNJ_S: {
            S :: u32(0x8000_0000)
            emu_write_freg(e, int(di.op.rd), nanbox_f32((u32(di.op.rs1_val) &~ S) | (u32(di.op.rs2_val) & S)))
            return u64(di.length), true
        }
        case .FSGNJN_S: {
            S :: u32(0x8000_0000)
            emu_write_freg(e, int(di.op.rd), nanbox_f32((u32(di.op.rs1_val) &~ S) | (~u32(di.op.rs2_val) & S)))
            return u64(di.length), true
        }
        case .FSGNJX_S: {
            S :: u32(0x8000_0000)
            emu_write_freg(e, int(di.op.rd), nanbox_f32(u32(di.op.rs1_val) ~ (u32(di.op.rs2_val) & S)))
            return u64(di.length), true
        }

        // --- Arithmetic (double) ---
        case .FADD_D: {
            emu_write_freg(e, int(di.op.rd), transmute(u64)(transmute(f64)di.op.rs1_val + transmute(f64)di.op.rs2_val))
            return u64(di.length), true
        }
        case .FSUB_D: {
            emu_write_freg(e, int(di.op.rd), transmute(u64)(transmute(f64)di.op.rs1_val - transmute(f64)di.op.rs2_val))
            return u64(di.length), true
        }
        case .FMUL_D: {
            emu_write_freg(e, int(di.op.rd), transmute(u64)(transmute(f64)di.op.rs1_val * transmute(f64)di.op.rs2_val))
            return u64(di.length), true
        }
        case .FDIV_D: {
            emu_write_freg(e, int(di.op.rd), transmute(u64)(transmute(f64)di.op.rs1_val / transmute(f64)di.op.rs2_val))
            return u64(di.length), true
        }

        // --- Arithmetic (single); operands NaN-boxed in the low 32 bits ---
        case .FADD_S: {
            emu_write_freg(e, int(di.op.rd), nanbox_f32(transmute(u32)(transmute(f32)u32(di.op.rs1_val) + transmute(f32)u32(di.op.rs2_val))))
            return u64(di.length), true
        }
        case .FSUB_S: {
            emu_write_freg(e, int(di.op.rd), nanbox_f32(transmute(u32)(transmute(f32)u32(di.op.rs1_val) - transmute(f32)u32(di.op.rs2_val))))
            return u64(di.length), true
        }
        case .FMUL_S: {
            emu_write_freg(e, int(di.op.rd), nanbox_f32(transmute(u32)(transmute(f32)u32(di.op.rs1_val) * transmute(f32)u32(di.op.rs2_val))))
            return u64(di.length), true
        }
        case .FDIV_S: {
            emu_write_freg(e, int(di.op.rd), nanbox_f32(transmute(u32)(transmute(f32)u32(di.op.rs1_val) / transmute(f32)u32(di.op.rs2_val))))
            return u64(di.length), true
        }

        // --- Comparisons (write 0/1 to an integer register) ---
        case .FEQ_D: {
            emu_write_reg(e, int(di.op.rd), 1 if transmute(f64)di.op.rs1_val == transmute(f64)di.op.rs2_val else 0)
            return u64(di.length), true
        }
        case .FLT_D: {
            emu_write_reg(e, int(di.op.rd), 1 if transmute(f64)di.op.rs1_val <  transmute(f64)di.op.rs2_val else 0)
            return u64(di.length), true
        }
        case .FLE_D: {
            emu_write_reg(e, int(di.op.rd), 1 if transmute(f64)di.op.rs1_val <= transmute(f64)di.op.rs2_val else 0)
            return u64(di.length), true
        }
        case .FEQ_S: {
            emu_write_reg(e, int(di.op.rd), 1 if transmute(f32)u32(di.op.rs1_val) == transmute(f32)u32(di.op.rs2_val) else 0)
            return u64(di.length), true
        }
        case .FLT_S: {
            emu_write_reg(e, int(di.op.rd), 1 if transmute(f32)u32(di.op.rs1_val) <  transmute(f32)u32(di.op.rs2_val) else 0)
            return u64(di.length), true
        }
        case .FLE_S: {
            emu_write_reg(e, int(di.op.rd), 1 if transmute(f32)u32(di.op.rs1_val) <= transmute(f32)u32(di.op.rs2_val) else 0)
            return u64(di.length), true
        }

        // --- Conversions: float <-> float ---
        case .FCVT_S_D: { // f64 -> f32
            emu_write_freg(e, int(di.op.rd), nanbox_f32(transmute(u32)f32(transmute(f64)di.op.rs1_val)))
            return u64(di.length), true
        }
        case .FCVT_D_S: { // f32 -> f64
            emu_write_freg(e, int(di.op.rd), transmute(u64)f64(transmute(f32)u32(di.op.rs1_val)))
            return u64(di.length), true
        }

        // --- Conversions: float -> integer (truncating; rd is integer) ---
        case .FCVT_W_S:  { emu_write_reg(e, int(di.op.rd), u64(i64(i32(transmute(f32)u32(di.op.rs1_val))))); return u64(di.length), true }
        case .FCVT_WU_S: { emu_write_reg(e, int(di.op.rd), u64(i64(i32(u32(transmute(f32)u32(di.op.rs1_val)))))); return u64(di.length), true }
        case .FCVT_L_S:  { emu_write_reg(e, int(di.op.rd), u64(i64(transmute(f32)u32(di.op.rs1_val)))); return u64(di.length), true }
        case .FCVT_LU_S: { emu_write_reg(e, int(di.op.rd), u64(transmute(f32)u32(di.op.rs1_val))); return u64(di.length), true }
        case .FCVT_W_D:  { emu_write_reg(e, int(di.op.rd), u64(i64(i32(transmute(f64)di.op.rs1_val)))); return u64(di.length), true }
        case .FCVT_WU_D: { emu_write_reg(e, int(di.op.rd), u64(i64(i32(u32(transmute(f64)di.op.rs1_val))))); return u64(di.length), true }
        case .FCVT_L_D:  { emu_write_reg(e, int(di.op.rd), u64(i64(transmute(f64)di.op.rs1_val))); return u64(di.length), true }
        case .FCVT_LU_D: { emu_write_reg(e, int(di.op.rd), u64(transmute(f64)di.op.rs1_val)); return u64(di.length), true }

        // --- Conversions: integer -> float (rs1_val is integer; rd is fp) ---
        case .FCVT_S_W:  { emu_write_freg(e, int(di.op.rd), nanbox_f32(transmute(u32)f32(i32(u32(di.op.rs1_val))))); return u64(di.length), true }
        case .FCVT_S_WU: { emu_write_freg(e, int(di.op.rd), nanbox_f32(transmute(u32)f32(u32(di.op.rs1_val)))); return u64(di.length), true }
        case .FCVT_S_L:  { emu_write_freg(e, int(di.op.rd), nanbox_f32(transmute(u32)f32(i64(di.op.rs1_val)))); return u64(di.length), true }
        case .FCVT_S_LU: { emu_write_freg(e, int(di.op.rd), nanbox_f32(transmute(u32)f32(di.op.rs1_val))); return u64(di.length), true }
        case .FCVT_D_W:  { emu_write_freg(e, int(di.op.rd), transmute(u64)f64(i32(u32(di.op.rs1_val)))); return u64(di.length), true }
        case .FCVT_D_WU: { emu_write_freg(e, int(di.op.rd), transmute(u64)f64(u32(di.op.rs1_val))); return u64(di.length), true }
        case .FCVT_D_L:  { emu_write_freg(e, int(di.op.rd), transmute(u64)f64(i64(di.op.rs1_val))); return u64(di.length), true }
        case .FCVT_D_LU: { emu_write_freg(e, int(di.op.rd), transmute(u64)f64(di.op.rs1_val)); return u64(di.length), true }

        // --- NOP ---
        case .NOP, .C_NOP: {
            return u64(di.length), true
        }

        case .INVALID: {
            return 0, false
        }
    }

    return 0, false
}

// --- Privileged state ----------------------------------------------------------

emu_read_csr :: proc(e: ^Emu64, addr: u16) -> u64 {
    return e.csr[addr] if addr in e.csr else 0
}

emu_write_csr :: proc(e: ^Emu64, addr: u16, value: u64) {
    e.csr[addr] = value
}

// Enter the supervisor trap handler: record where the trap came from and why,
// stash the interrupt-enable state, then jump to stvec. `epc` is the address of
// the faulting instruction, so the handler decides whether to retry it or step
// past it -- for an ecall the kernel resumes at epc+4.
emu_trap_to_supervisor :: proc(e: ^Emu64, cause: u64, tval: u64, epc: u64) {
    status := emu_read_csr(e, CSR_SSTATUS)

    // SPIE remembers whether interrupts were on; SPP remembers the old mode.
    status = (status &~ SSTATUS_SPIE) | (SSTATUS_SPIE if (status & SSTATUS_SIE) != 0 else 0)
    status &~= SSTATUS_SIE
    status = (status &~ SSTATUS_SPP) | (SSTATUS_SPP if e.mode == .Supervisor else 0)

    emu_write_csr(e, CSR_SSTATUS, status)
    emu_write_csr(e, CSR_SEPC, epc)
    emu_write_csr(e, CSR_SCAUSE, cause)
    emu_write_csr(e, CSR_STVAL, tval)

    e.mode = .Supervisor
    e.pc = emu_read_csr(e, CSR_STVEC) &~ u64(0b11) // low bits select the trap mode
}

// Return from a supervisor trap: restore the privilege level and interrupt state
// that SPP/SPIE recorded, then resume at sepc. This is also how the kernel enters
// user mode for the first time -- it sets sepc and clears SPP, then executes sret.
emu_sret :: proc(e: ^Emu64) {
    status := emu_read_csr(e, CSR_SSTATUS)

    e.mode = .Supervisor if (status & SSTATUS_SPP) != 0 else .User

    status = (status &~ SSTATUS_SIE) | (SSTATUS_SIE if (status & SSTATUS_SPIE) != 0 else 0)
    status |= SSTATUS_SPIE
    status &~= SSTATUS_SPP

    emu_write_csr(e, CSR_SSTATUS, status)
    e.pc = emu_read_csr(e, CSR_SEPC)
}

// CSR read-modify-write. Every variant reads the old value into rd and then
// applies its write, so a read-only use (rd = csr, rs1 = x0) leaves it untouched.
eval_csr :: proc(e: ^Emu64, di: Instr) -> (pc_offset: u64, cont: bool) {
    if e.mode == .User {
        emu_trap_to_supervisor(e, CAUSE_ILLEGAL_INSTR, u64(di.raw), di.addr)
        return 0, true
    }

    addr := u16(di.op.imm)
    old := emu_read_csr(e, addr)

    // The immediate forms take a 5-bit unsigned value from the rs1 field.
    source := di.op.rs1_val
    #partial switch di.mnemonic {
        case .CSRRWI, .CSRRSI, .CSRRCI: source = u64(di.op.rs1)
    }

    new_value := old
    #partial switch di.mnemonic {
        case .CSRRW, .CSRRWI: new_value = source
        case .CSRRS, .CSRRSI: if source != 0 do new_value = old | source
        case .CSRRC, .CSRRCI: if source != 0 do new_value = old &~ source
    }

    if new_value != old do emu_write_csr(e, addr, new_value)
    emu_write_reg(e, int(di.op.rd), old)

    return u64(di.length), true
}

eval_ecall :: proc(e: ^Emu64, di: Instr) -> (pc_offset: u64, cont: bool) {
    SYS_SHUTDOWN         :: 0xFE
    SYS_TRAP             :: 0xFF
    SYS_MEMSET           :: 0x09
    SYS_PRINTLN          :: 0x0A
    SYS_CALL_HOST        :: 0x0B
    SYS_PUSH_STACK       :: 0x02
    SYS_POP_STACK        :: 0x03

    SYS_STACK_FN_U32     :: 0x01
    SYS_STACK_FN_POINTER :: 0x02

    SYS_LINUX_WRITE      :: 0x40

    // Application images, for the guest kernel's loader. The kernel asks for a
    // size, allocates a staging buffer, then asks for the bytes.
    SBI_IMAGE_SIZE       :: 0x20 // (name_ptr, name_len) -> size, 0 if unknown
    SBI_IMAGE_READ       :: 0x21 // (name_ptr, name_len, dest) -> bytes written

    // The timer the kernel preempts with.
    SBI_TIME             :: 0x30 // -> ticks since the machine started
    SBI_SET_TIMER        :: 0x31 // (deadline) -> arms it, and clears the old one

    // The display. Pixels arrive a block at a time, because the frames behind a
    // grant are not contiguous, and are shown only when the guest says so.
    SBI_DISPLAY_INFO     :: 0x50 // -> width in the high 32 bits, height in the low
    SBI_DISPLAY_BLIT     :: 0x51 // (paddr, offset, len) -> bytes taken
    SBI_DISPLAY_SHOW     :: 0x52 // -> shows what has been blitted

    sys_call_id := emu_read_reg(e, 17)

    switch sys_call_id {
        case SYS_SHUTDOWN: {
            e.stop_reason = .Halt
            return 0, false
        }
        case SYS_TRAP: {
            trap_code := emu_read_reg(e, 10)
            fmt.eprintf("\n\nTRAP: 0x%x\n\n", trap_code)
            e.stop_reason = .Trap
            return 0, false
        }
        case SYS_LINUX_WRITE: {
            fd := emu_read_reg(e, 10)
            buf := emu_read_reg(e, 11)
            count := emu_read_reg(e, 12)

            str_buf := make([]u8, count, allocator = context.temp_allocator)
            for i in 0..<count {
                str_buf[i] = emu_read_u8(e, buf+i)
            }
            str := string(str_buf)

            fmt.eprintf("%v", str)
            fmt.eprintf("\nSYS_LINUX_WRITE: %v\n\n", str)

            emu_write_reg(e, 10, count)
        }
        case SBI_TIME: {
            emu_write_reg(e, 10, e.ticks)
        }
        case SBI_SET_TIMER: {
            // Arming the timer is also how the guest acknowledges the last one:
            // the pending bit would otherwise re-enter the handler forever.
            emu_write_csr(e, CSR_SIP, emu_read_csr(e, CSR_SIP) &~ SIP_STIP)
            e.timer_deadline = emu_read_reg(e, 10)
            e.timer_armed = true
        }
        case SBI_DISPLAY_INFO: {
            emu_write_reg(e, 10, (u64(e.display.width) << 32) | u64(e.display.height))
        }
        case SBI_DISPLAY_BLIT: {
            paddr := emu_read_reg(e, 10)
            offset := emu_read_reg(e, 11)
            length := emu_read_reg(e, 12)

            // Clamp rather than trust: the guest names a physical address and a
            // length, and neither has to fit the framebuffer.
            if offset >= u64(len(e.display.pixels)) {
                emu_write_reg(e, 10, 0)
                break
            }
            length = min(length, u64(len(e.display.pixels)) - offset)

            for i in 0 ..< length {
                e.display.pixels[offset + i] = phys_read_u8(e, paddr + i)
            }

            emu_write_reg(e, 10, length)
        }
        case SBI_DISPLAY_SHOW: {
            if e.display.show != nil {
                e.display.show(e.display.width, e.display.height, e.display.pixels)
            }
        }
        case SBI_IMAGE_SIZE: {
            name := emu_read_string(e, emu_read_reg(e, 10), emu_read_reg(e, 11))

            image, ok := emu_image_bytes(e, name)
            if !ok {
                emu_write_reg(e, 10, 0)
                break
            }

            emu_write_reg(e, 10, u64(len(image)))
        }
        case SBI_IMAGE_READ: {
            name := emu_read_string(e, emu_read_reg(e, 10), emu_read_reg(e, 11))
            dest := emu_read_reg(e, 12)

            image, ok := emu_image_bytes(e, name)
            if !ok {
                emu_write_reg(e, 10, 0)
                break
            }

            // dest is a supervisor virtual address, so this writes through the
            // guest's page tables and lands wherever the kernel staged it.
            emu_copy_into_mem(e, image, dest)
            emu_write_reg(e, 10, u64(len(image)))
        }
        case SYS_MEMSET: {
            addr := emu_read_reg(e, 10)
            value := emu_read_reg(e, 11)
            len := emu_read_reg(e, 12)

            for i in 0..<len {
                emu_write_u8(e, addr+i, u8(value))
            }
        }
        case SYS_PRINTLN: {
            str_addr := emu_read_reg(e, 10)
            str_len := emu_read_reg(e, 11)

            str_buf := make([]u8, str_len, allocator = context.temp_allocator)
            for i in 0..<str_len {
                str_buf[i] = emu_read_u8(e, str_addr+i)
            }
            str := string(str_buf)

            fmt.eprintf("%v", str)
            fmt.eprintf("\nSYS_PRINTLN: %v\n\n", str)
        }
        case SYS_CALL_HOST: {
            func_name_addr := emu_read_reg(e, 10)
            func_name_len := emu_read_reg(e, 11)

            func_name := emu_read_string(e, func_name_addr, func_name_len)

            if f, ok := e.host_functions[func_name]; ok {
                if ok := f.fn(e, f.user_data); !ok {
                    fmt.eprintf("Host Function '%v' returned error\n", func_name)
                }
            }
            else if func_name == "core::println" {
                str_addr := emu_comm_stack_pop_u64(e) or_break
                str_len := emu_comm_stack_pop_u32(e) or_break

                str := emu_read_string(e, str_addr, u64(str_len))
                fmt.eprintf("%v", str)
            } else if func_name == "core::readln" {
                buf := "test input"
                for i in 0..<len(buf) {
                    emu_write_u8(e, 0x800000000+u64(i), buf[i])
                }

                emu_comm_stack_push(e, EmuArgU64(len(buf)))
                emu_comm_stack_push(e, EmuArgU64(0x800000000))
            } else {
                fmt.eprintf("\nInvalid CALL_HOST function: %s\n\n", func_name)
            }
        }
        case SYS_PUSH_STACK: {
            func := emu_read_reg(e, 10)
            value := emu_read_reg(e, 11)

            switch func {
                case SYS_STACK_FN_U32: {
                    emu_comm_stack_push(e, EmuArgU32(i32(value & 0xFFFFFFFF)))
                }
                case SYS_STACK_FN_POINTER: {
                    emu_comm_stack_push(e, EmuArgU64(u64(value)))
                }
                case: {
                    fmt.eprintf("\nInvalid PUSH_STACK function: 0x%x\n\n", func)
                }
            }
        }
        case SYS_POP_STACK: {
            func := emu_read_reg(e, 10)
            value, ok := emu_comm_stack_pop(e)
            if !ok {
                fmt.eprintf("\nInvalid POP_STACK call: nothing on the stack\n\n")
                return 4, true
            }

            switch func {
                case SYS_STACK_FN_U32: {
                    switch v in value {
                        case EmuArgU32: {
                            emu_write_reg(e, 10, u64(u32(v)))
                        }
                        case EmuArgU64: {
                            fmt.eprintf("\nInvalid POP_STACK call: invalid type, emu wanted U32, got U64\n\n")
                        }
                    }
                }
                case SYS_STACK_FN_POINTER: {
                    switch v in value {
                        case EmuArgU32: {
                            fmt.eprintf("\nInvalid POP_STACK call: invalid type, emu wanted U64, got U32\n\n")
                        }
                        case EmuArgU64: {
                            emu_write_reg(e, 10, u64(v))
                        }
                    }
                }
                case: {
                    fmt.eprintf("\nInvalid POP_STACK function: 0x%x\n\n", func)
                }
            }
        }
        case: {
            fmt.eprintf("\nInvalid SYSCALL 0x%x\n\n", sys_call_id)
            emu_write_reg(e, 10, 0xFEFEFEFEFEFEFEFE)
        }
    }

    return 4, true
}

// Execute exactly one instruction at pc and report why we stopped (.None if it
// simply advanced). The single primitive emu_run is built on. stop_reason is
// pre-set to .Invalid so any halting instruction that does not set it (an
// undecodable or unhandled instruction) reports a fault.
emu_step :: proc(e: ^Emu64) -> StopReason {
    if e.pc == EMU_HALT_VECTOR do return .Halt

    e.ticks += 1
    if e.timer_armed && e.ticks >= e.timer_deadline {
        e.timer_armed = false
        emu_write_csr(e, CSR_SIP, emu_read_csr(e, CSR_SIP) | SIP_STIP)
    }

    // An interrupt is taken between instructions, so the one about to run has not
    // run yet and is exactly where the handler should resume.
    if emu_take_interrupt(e) do return .None

    e.stop_reason = .Invalid
    e.fault_pending = false

    instr := emu_decode_instr(e)

    // A fault on the fetch itself means nothing executed, so the trap is precise.
    if e.fault_pending {
        emu_deliver_fault(e, instr.addr)
        return .None
    }

    offset, cont := emu_eval_instr(e, instr)

    // A fault during a load or store: the instruction may already have written a
    // register, but the trap still lands with sepc on the faulting instruction.
    if e.fault_pending {
        emu_deliver_fault(e, instr.addr)
        return .None
    }

    e.pc += offset

    if cont do return .None
    return e.stop_reason
}

// Take a pending, enabled interrupt if the current privilege level permits it.
//
// An interrupt bound for supervisor mode is always taken while user code runs,
// because supervisor outranks user. In supervisor mode it is taken only while
// sstatus.SIE is set -- so a kernel that leaves SIE clear is never interrupted in
// the middle of its own work, and only user code gets preempted.
@(private)
emu_take_interrupt :: proc(e: ^Emu64) -> bool {
    if e.mode == .Machine do return false

    pending := emu_read_csr(e, CSR_SIP) & emu_read_csr(e, CSR_SIE)
    if pending == 0 do return false

    if e.mode == .Supervisor && (emu_read_csr(e, CSR_SSTATUS) & SSTATUS_SIE) == 0 {
        return false
    }

    if (pending & SIP_STIP) != 0 {
        emu_trap_to_supervisor(e, CAUSE_INTERRUPT | IRQ_S_TIMER, 0, e.pc)
        return true
    }

    return false
}

@(private)
emu_deliver_fault :: proc(e: ^Emu64, epc: u64) {
    e.fault_pending = false
    emu_trap_to_supervisor(e, e.fault_cause, e.fault_addr, epc)
}

// Run the machine until it stops advancing: a clean halt, a trap, or a fault.
emu_run :: proc(e: ^Emu64) -> StopReason {
    for {
        r := emu_step(e)
        if r == .None do continue

        // An undecodable instruction says nothing about where the guest went
        // wrong, and by then the pc is the only clue left. Report it.
        if r == .Invalid {
            fmt.eprintf("\nundecodable instruction at pc=0x%x, mode=%v\n\n", e.pc, e.mode)
        }

        return r
    }
}


unscramble_imm :: proc(scrambled: u32, mapping: []u8) -> (imm: u32) {
    num_bits := u32(len(mapping))

    i: u32
    for i < num_bits {
        contiguous_index := i

        for j in (i+1)..<num_bits {
            if mapping[j] == mapping[j-1]-1 {
                contiguous_index = j
            } else {
                break
            }
        }

        mask: u32
        for j in i..=contiguous_index {
            mask |= 1 << (num_bits-j-1)
        }

        scram_bit := num_bits-i-1
        bit := u32(mapping[i])

        if scram_bit > bit {
            imm |= (scrambled&mask)>>(scram_bit-bit)
        } else {
            imm |= (scrambled&mask)<<(bit-scram_bit)
        }

        i = contiguous_index+1
    }

    return
}


emu_write_reg :: proc(e: ^Emu64, reg: int, value: u64, loc := #caller_location) {
    if reg == 0 { return }

    e.reg[reg-1] = value
}

emu_write_reg_cext :: proc(e: ^Emu64, reg: int, value: u64, loc := #caller_location) {
    emu_write_reg(e, reg+8, value)
}

emu_read_reg :: proc(e: ^Emu64, reg: int, loc := #caller_location) -> u64 {
    if reg == 0 { return 0 }

    return e.reg[reg-1]
}

emu_read_reg_cext :: proc(e: ^Emu64, reg: int, loc := #caller_location) -> u64 {
    return emu_read_reg(e, reg+8)
}

// --- Floating-point register helpers ---
// The FP file has no hardwired-zero register, so f0..f31 index directly. A
// single-precision value is NaN-boxed into a 64-bit slot (upper 32 bits set).

nanbox_f32 :: proc(bits: u32) -> u64 {
    return 0xFFFF_FFFF_0000_0000 | u64(bits)
}

emu_write_freg :: proc(e: ^Emu64, reg: int, value: u64, loc := #caller_location) {
    e.freg[reg] = value
}

emu_read_freg :: proc(e: ^Emu64, reg: int, loc := #caller_location) -> u64 {
    return e.freg[reg]
}

emu_write_freg_cext :: proc(e: ^Emu64, reg: int, value: u64, loc := #caller_location) {
    emu_write_freg(e, reg+8, value)
}

emu_read_freg_cext :: proc(e: ^Emu64, reg: int, loc := #caller_location) -> u64 {
    return emu_read_freg(e, reg+8)
}

emu_instr_jump :: proc(e: ^Emu64, addr: u64) -> (pc_offset: u64, cont: bool) {
    e.pc = addr

    return 0, true
}

emu_instr_jump_rel :: proc(e: ^Emu64, addr: i32) -> (pc_offset: u64, cont: bool) {
    if addr > 0 {
        e.pc += u64(addr)
    } else {
        e.pc -= u64(-addr)
    }

    return 0, true
}

sign_extend_u32 :: proc(value: u32, bits: u32) -> i32 {
    mask: u32 = 1 << (bits - 1)

    return i32((value ~ mask) - mask)
}

sign_extend_u16 :: proc(value: u16, bits: u16) -> i16 {
    mask: u16 = 1 << (bits - 1)

    return i16((value ~ mask) - mask)
}

sign_extend_u8 :: proc(value: u8, bits: u8) -> i8 {
    mask: u8 = 1 << (bits - 1)

    return i8((value ~ mask) - mask)
}


@(test)
sign_extend_Test :: proc(t: ^testing.T) {

    num_7bit: u8 = 0b00111110 // -2 in 7bit 2's compliment

    num_8bit_signed := sign_extend_u8(num_7bit, 6)

    num_16bit_signed := i16(num_8bit_signed)

    testing.expect_value(t, num_8bit_signed, -2)
    testing.expect_value(t, num_16bit_signed, -2)
}

// Regression test for the RV64M + logical/word instructions that were missing or
// mis-decoded/mis-evaluated (XOR/OR/DIV/REM/MUL*-high, and the *W ops). Each case
// assembles a single instruction with rd=x5, rs1=x6, rs2=x7, executes it through
// the full decode+eval pipeline via emu_step, and checks the result in x5.
@(test)
rv64m_logical_word_Test :: proc(t: ^testing.T) {
    e := emu_make(1024 * 1024)
    defer {
        delete(e.page_table.pages)
        delete(e.host_functions)
        delete(e.page_arena.data)
    }

    PC :: u64(0x8000_0000)
    RD :: u32(5)
    RS1 :: u32(6)
    RS2 :: u32(7)

    enc_r  :: proc(op, funct7, funct3: u32) -> u32 { return op | (RD << 7) | (funct3 << 12) | (RS1 << 15) | (RS2 << 20) | (funct7 << 25) }
    enc_iw :: proc(funct3, imm: u32) -> u32 { return 0b0011011 | (RD << 7) | (funct3 << 12) | (RS1 << 15) | (imm << 20) }

    run :: proc(t: ^testing.T, e: ^Emu64, raw: u32, rs1v, rs2v: u64) -> u64 {
        emu_write_u32(e, PC, raw)
        e.pc = PC
        emu_write_reg(e, int(RS1), rs1v)
        emu_write_reg(e, int(RS2), rs2v)
        emu_write_reg(e, int(RD), 0)
        testing.expect_value(t, emu_step(e), StopReason.None)
        return emu_read_reg(e, int(RD))
    }

    OP_R  :: u32(0b0110011) // RV64I/M register ops
    OP_RW :: u32(0b0111011) // RV64 *W register ops
    NEG1  :: u64(0xFFFF_FFFF_FFFF_FFFF)
    IMIN  :: u64(0x8000_0000_0000_0000)

    // --- logical (were decoded as INVALID) ---
    testing.expect_value(t, run(t, &e, enc_r(OP_R, 0b0000000, 0b100), 0xF0, 0x0F), 0xFF)        // XOR
    testing.expect_value(t, run(t, &e, enc_r(OP_R, 0b0000000, 0b110), 0xF0, 0x0F), 0xFF)        // OR

    // --- divide/remainder (signed/unsigned + the defined edge cases) ---
    testing.expect_value(t, run(t, &e, enc_r(OP_R, 0b0000001, 0b100), 100, 7), 14)              // DIV
    testing.expect_value(t, run(t, &e, enc_r(OP_R, 0b0000001, 0b100), 100, 0), NEG1)            // DIV by 0 -> -1
    testing.expect_value(t, run(t, &e, enc_r(OP_R, 0b0000001, 0b100), IMIN, NEG1), IMIN)        // DIV overflow -> MIN
    testing.expect_value(t, run(t, &e, enc_r(OP_R, 0b0000001, 0b110), 100, 7), 2)               // REM
    testing.expect_value(t, run(t, &e, enc_r(OP_R, 0b0000001, 0b110), 100, 0), 100)             // REM by 0 -> dividend
    testing.expect_value(t, run(t, &e, enc_r(OP_R, 0b0000001, 0b101), 100, 7), 14)              // DIVU
    testing.expect_value(t, run(t, &e, enc_r(OP_R, 0b0000001, 0b101), 100, 0), NEG1)            // DIVU by 0 -> all ones
    testing.expect_value(t, run(t, &e, enc_r(OP_R, 0b0000001, 0b111), 100, 7), 2)               // REMU
    testing.expect_value(t, run(t, &e, enc_r(OP_R, 0b0000001, 0b111), 100, 0), 100)             // REMU by 0 -> dividend

    // --- multiply-high (funct7 was ignored -> mis-decoded as SLL/SLT/SLTU) ---
    testing.expect_value(t, run(t, &e, enc_r(OP_R, 0b0000001, 0b000), 6, 7), 42)                // MUL
    testing.expect_value(t, run(t, &e, enc_r(OP_R, 0b0000001, 0b001), NEG1, NEG1), 0)           // MULH(-1,-1) hi = 0
    testing.expect_value(t, run(t, &e, enc_r(OP_R, 0b0000001, 0b011), NEG1, NEG1), 0xFFFF_FFFF_FFFF_FFFE) // MULHU
    testing.expect_value(t, run(t, &e, enc_r(OP_R, 0b0000001, 0b010), NEG1, 2), NEG1)           // MULHSU(-1, 2u) hi = -1

    // sanity: SLL/SLT/SLTU still decode correctly (funct7 = 0)
    testing.expect_value(t, run(t, &e, enc_r(OP_R, 0b0000000, 0b001), 1, 4), 16)                // SLL 1<<4
    testing.expect_value(t, run(t, &e, enc_r(OP_R, 0b0000000, 0b011), 1, 2), 1)                 // SLTU 1<2

    // --- 64-bit *W register ops ---
    testing.expect_value(t, run(t, &e, enc_r(OP_RW, 0b0100000, 0b000), 5, 8), 0xFFFF_FFFF_FFFF_FFFD)  // SUBW 5-8
    testing.expect_value(t, run(t, &e, enc_r(OP_RW, 0b0000001, 0b000), 0x1_0000_0002, 3), 6)          // MULW (low32 only)
    testing.expect_value(t, run(t, &e, enc_r(OP_RW, 0b0000000, 0b001), 1, 31), 0xFFFF_FFFF_8000_0000)  // SLLW 1<<31 (sign-ext)
    testing.expect_value(t, run(t, &e, enc_r(OP_RW, 0b0000000, 0b101), 0x8000_0000, 4), 0x0800_0000)   // SRLW logical
    testing.expect_value(t, run(t, &e, enc_r(OP_RW, 0b0100000, 0b101), 0x8000_0000, 4), 0xFFFF_FFFF_F800_0000) // SRAW arith

    // --- 64-bit *W immediate shifts ---
    testing.expect_value(t, run(t, &e, enc_iw(0b001, 3), 1, 0), 8)                                       // SLLIW 1<<3
    testing.expect_value(t, run(t, &e, enc_iw(0b101, 4), 0x8000_0000, 0), 0x0800_0000)                   // SRLIW
    testing.expect_value(t, run(t, &e, enc_iw(0b101, (0b0100000 << 5) | 4), 0x8000_0000, 0), 0xFFFF_FFFF_F800_0000) // SRAIW
}
