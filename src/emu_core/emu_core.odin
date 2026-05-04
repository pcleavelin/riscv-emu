package emu_core

import "base:runtime"
import "core:os"
import "core:testing"
import "core:fmt"
import "core:math/bits"

REG_X2 :: 2

Emu64 :: struct {
    reg: [31]u64,
    pc: u64,

    page_table: EmuPageTable,

    break_points: [dynamic]u64,

    running: bool,
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


emu_make :: proc(max_memory: int) -> Emu64 {
    return Emu64 {
        page_table = emu_make_page_table(1024 * 16),
    }
}

emu_make_page_table :: proc(page_size: u64, allocator := context.allocator) -> EmuPageTable {
    assert(page_size%16 == 0)

    return EmuPageTable {
        page_size = page_size,
        pages = make(map[u64]EmuMemoryPage, allocator),
    }
}

emu_set_break_point :: proc(e: ^Emu64, addr: u64) {
    if e.break_points == nil {
        e.break_points = make([dynamic]u64)
    }

    append(&e.break_points, addr)
}

emu_load_elf :: proc(e: ^Emu64, file_path: string) -> (start_addr: u64, ok: bool) {
    content, read_error := os.read_entire_file_from_path(file_path, context.allocator)
    if read_error != nil {
        fmt.println("error reading ELF:", read_error)
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

    fmt.printf("header_loc: 0x%x\n", header_loc)
    fmt.printf("num entries: %d\n", num_entries)
    fmt.printf("entry size: 0x%x\n", entry_size)
    fmt.printf("entry point: 0x%x\n", entry_point_addr)

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

        fmt.printf("p_type: 0x%x\n", p_type)
        fmt.printf("p_offset: 0x%x\n", p_offset)
        fmt.printf("p_vaddr: 0x%x\n", p_vaddr)
        fmt.printf("p_paddr: 0x%x\n", p_paddr)
        fmt.printf("p_filesz: 0x%x\n", p_filesz)
        fmt.printf("p_memsz: 0x%x\n", p_memsz)
        fmt.println("--")

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

emu_read_u64 :: proc(e: ^Emu64, vaddr: u64, loc := #caller_location) -> u64 {
    page := emu_get_page(e, vaddr)
    assert(page != nil, "no page found")

    offset := vaddr - page.start_addr
    assert(offset+7 < u64(len(page.virtual_mem)), "u64 crosses page boundary", loc)

    return u64((transmute(^u64)(&page.virtual_mem[offset]))^)
}

emu_read_u32 :: proc(e: ^Emu64, vaddr: u64, loc := #caller_location) -> u32 {
    page := emu_get_page(e, vaddr)
    assert(page != nil, "no page found")

    offset := vaddr - page.start_addr
    assert(offset+3 < u64(len(page.virtual_mem)), "u32 crosses page boundary", loc)

    return u32((transmute(^u32)(&page.virtual_mem[offset]))^)
}

emu_read_u16 :: proc(e: ^Emu64, vaddr: u64, loc := #caller_location) -> u16 {
    page := emu_get_page(e, vaddr)
    assert(page != nil, "no page found")

    offset := vaddr - page.start_addr
    assert(offset+1 < u64(len(page.virtual_mem)), "u16 crosses page boundary", loc)

    return u16((transmute(^u16)(&page.virtual_mem[offset]))^)
}

emu_read_u8 :: proc(e: ^Emu64, vaddr: u64, loc := #caller_location) -> u8 {
    page := emu_get_page(e, vaddr)
    assert(page != nil, "no page found")

    offset := vaddr - page.start_addr

    return u8((transmute(^u8)(&page.virtual_mem[offset]))^)
}

emu_write_u64 :: proc(e: ^Emu64, vaddr: u64, value: u64) {
    page := emu_get_page(e, vaddr)
    assert(page != nil, "no page found")

    offset := vaddr - page.start_addr
    assert(offset+7 < u64(len(page.virtual_mem)), "u64 crosses page boundary")

    for i in 0..<8 {
        page.virtual_mem[int(offset)+i] = u8((value>>(uint(i)*8))&0xFF)
    }
}

emu_write_u32 :: proc(e: ^Emu64, vaddr: u64, value: u32) {
    page := emu_get_page(e, vaddr)
    assert(page != nil, "no page found")

    offset := vaddr - page.start_addr
    assert(offset+3 < u64(len(page.virtual_mem)), "u32 crosses page boundary")

    for i in 0..<4 {
        page.virtual_mem[int(offset)+i] = u8((value>>(uint(i)*8))&0xFF)
    }
}

emu_write_u16 :: proc(e: ^Emu64, vaddr: u64, value: u16) {
    page := emu_get_page(e, vaddr)
    assert(page != nil, "no page found")

    offset := vaddr - page.start_addr
    assert(offset+1 < u64(len(page.virtual_mem)), "u16 crosses page boundary")

    for i in 0..<2 {
        page.virtual_mem[int(offset)+i] = u8((value>>(uint(i)*8))&0xFF)
    }
}

emu_write_u8 :: proc(e: ^Emu64, vaddr: u64, value: u8) {
    page := emu_get_page(e, vaddr)
    assert(page != nil, "no page found")

    offset := vaddr - page.start_addr
    page.virtual_mem[offset] = value
}

emu_get_page :: proc(e: ^Emu64, vaddr: u64) -> ^EmuMemoryPage {
    page_index := vaddr/e.page_table.page_size
    page, ok := &e.page_table.pages[page_index]
    // assert(ok, "page hasn't been created yet")
    if !ok {
        e.page_table.pages[page_index] = EmuMemoryPage {
            start_addr = e.page_table.page_size * page_index,
            virtual_mem = make([]u8, e.page_table.page_size),
        }

        return &e.page_table.pages[page_index]
    }

    return page
}

emu_run_addr :: proc(e: ^Emu64, addr: u64) {
    e.pc = addr

    emu_run(e)
}

emu_run :: proc(e: ^Emu64) {
    e.running = true

    for e.running {
        instruction_lo := emu_read_u16(e, e.pc)

        prefix := instruction_lo&0b11

        fmt.printf("Running instruction at 0x%16x: 0x%4x (0b%16b) opcode: 0b%7b", e.pc, instruction_lo, instruction_lo, instruction_lo&0b1111111)

        old_pc := e.pc

        switch prefix {
            case 0b00: {
                fmt.printf(" - RVC (Q0)")
                offset, cont := emu_do_rvc_q0(e, instruction_lo)

                e.running = cont
                e.pc += offset
            }
            case 0b01: {
                fmt.printf(" - RVC (Q1)")
                offset, cont := emu_do_rvc_q1(e, instruction_lo)

                e.running = cont
                e.pc += offset
            }
            case 0b10: {
                fmt.printf(" - RVC (Q2)")
                offset, cont := emu_do_rvc_q2(e, instruction_lo)

                e.running = cont
                e.pc += offset
            }

            // >16b
            case 0b11: {
                fmt.printf(" - RV32/64")
                offset, cont := emu_do_rv64(e)

                e.running = cont
                e.pc += offset
            }
        }

        for bp in e.break_points {
            if bp == old_pc {
                e.running = false
                fmt.println("\nHit Breakpoint")
                break
            }
        }

        fmt.printf("regs: %x\n", e.reg)

        runtime.free_all(context.temp_allocator)
    }
}

emu_do_rv64 :: proc(e: ^Emu64) -> (pc_offset: u64, cont: bool) {
    OP_JAL                     :: 0b1101111
    OP_JALR                    :: 0b1100111

    OP_LUI                     :: 0b0110111
    OP_AUIPC                   :: 0b0010111

    OP_ARITHMETIC_GROUP        :: 0b0110011
    OP_ARITHMETIC_64_GROUP     :: 0b0011011
    OP_BRANCH_GROUP            :: 0b1100011
    OP_STORE_GROUP             :: 0b0100011
    OP_LOAD_GROUP              :: 0b0000011

    OP_SIGNED_ARITHMETIC_GROUP :: 0b0010011

    OP_ECALL                   :: 0b1110011

    instr := EmuInstruction32{}
    instr.raw_instruction = u32(emu_read_u16(e, e.pc)) | (u32(emu_read_u16(e, e.pc+2)) << 16)

    if instr.opcode.v == OP_JAL {
        // J-Type
        imm_32 := (u32(instr.j_type.imm_hi) << 12) | (u32(instr.j_type.imm_lo) << 1) | (u32(instr.j_type.imm_mid) << 11) | (u32(instr.j_type.imm_msb) << 20)

        imm := sign_extend_u32(imm_32, 21)

        fmt.printf(" - jal x%d, 0x%x\n", instr.j_type.rd, imm)

        emu_write_reg(e, int(instr.j_type.rd), e.pc + 4)
        return emu_instr_jump_rel(e, imm)
    }
    else if instr.opcode.v == OP_LUI {
        // U-Type
        imm := i64(i32(instr.u_type.imm << 12))

        fmt.printf(" - lui x%d, 0x%x\n", instr.u_type.rd, imm)

        emu_write_reg(e, int(instr.u_type.rd), u64(imm))

        return 4, true
    }
    else if instr.opcode.v == OP_AUIPC {
        // U-Type
        imm := i64(i32(instr.u_type.imm<<12))

        result: u64
        if imm > 0 {
            result = e.pc + u64(imm)
        } else {
            result = e.pc - u64(-imm)
        }

        fmt.printf(" - auipc x%d <- (0x%x)\n", instr.u_type.rd, result)

        emu_write_reg(e, int(instr.u_type.rd), result)

        return 4, true
    }
    else if instr.opcode.v == OP_JALR || instr.opcode.v == OP_LOAD_GROUP || instr.opcode.v == 0b0010011  {
        // I-Type

        // TODO
        fmt.printf(" - Load and Math")

        switch instr.opcode.v {
            case OP_JALR: {
                rs1_i32 := i64(emu_read_reg(e, int(instr.i_type.rs1)))
                imm_i32 := i64(sign_extend_u16(instr.i_type.imm, 12))

                addr := u64((rs1_i32 + imm_i32))&(~u64(1))

                fmt.printf(" - jalr x%d, 0x%x\n", instr.i_type.rs1, imm_i32)

                emu_write_reg(e, int(instr.i_type.rd), e.pc + 4)

                return emu_instr_jump(e, addr)
            }
            case OP_LOAD_GROUP: {
                return emu_do_load_instr(e, instr.i_type)
            }
            case OP_SIGNED_ARITHMETIC_GROUP: {
                return emu_do_signed_arithmetic_instr(e, instr.i_type)
            }
        }

        fmt.printf("\n")
    }
    else if instr.opcode.v == OP_ARITHMETIC_GROUP {
        // R-Type
        fmt.printf(" - OP_ARITHMETIC_GROUP 0b%3b", instr.i_type.funct_3)

        switch instr.i_type.funct_3 {
            case 0b000: {
                rs1_val := emu_read_reg(e, int(instr.r_type.rs1))
                rs2_val := emu_read_reg(e, int(instr.r_type.rs2))

                result: u64

                switch instr.r_type.funct_7 {
                    case 0b0000000: {
                        result = rs1_val + rs2_val
                        fmt.printf(" - add x%d, x%d, x%d\n", instr.r_type.rd, instr.r_type.rs1, instr.r_type.rs2)
                    }
                    case 0b0100000: {
                        result = rs1_val - rs2_val

                        fmt.printf(" - sub x%d, x%d, x%d\n", instr.r_type.rd, instr.r_type.rs1, instr.r_type.rs2)
                    }
                    case 0b0000001: {
                        result = rs1_val * rs2_val

                        fmt.printf(" - mul x%d, x%d, x%d\n", instr.r_type.rd, instr.r_type.rs1, instr.r_type.rs2)
                    }
                    case: {
                        return 0, false
                    }
                }

                emu_write_reg(e, int(instr.r_type.rd), result)

                return 4, true
            }
            case 0b001: {
                rs1_val := emu_read_reg(e, int(instr.r_type.rs1))
                rs2_val := emu_read_reg(e, int(instr.r_type.rs2))&0x3f

                result := rs1_val << rs2_val

                fmt.printf(" - sll x%d, x%d, x%d\n", instr.r_type.rd, instr.r_type.rs1, instr.r_type.rs2)

                emu_write_reg(e, int(instr.r_type.rd), result)

                return 4, true
            }
            case 0b010: {
                rs1_val := i64(emu_read_reg(e, int(instr.r_type.rs1)))
                rs2_val := i64(emu_read_reg(e, int(instr.r_type.rs2)))

                fmt.printf(" - slt x%d, x%d, x%d\n", instr.r_type.rd, instr.r_type.rs1, instr.r_type.rs2)

                if rs1_val < rs2_val {
                    emu_write_reg(e, int(instr.r_type.rd), 1)
                } else {
                    emu_write_reg(e, int(instr.r_type.rd), 0)
                }

                return 4, true
            }
            case 0b011: {
                rs1_val := emu_read_reg(e, int(instr.r_type.rs1))
                rs2_val := emu_read_reg(e, int(instr.r_type.rs2))

                fmt.printf(" - sltu x%d, x%d, x%d\n", instr.r_type.rd, instr.r_type.rs1, instr.r_type.rs2)

                if rs1_val < rs2_val {
                    emu_write_reg(e, int(instr.r_type.rd), 1)
                } else {
                    emu_write_reg(e, int(instr.r_type.rd), 0)
                }

                return 4, true
            }
            case 0b100: {}
            case 0b101: {
                rs1_val := emu_read_reg(e, int(instr.r_type.rs1))
                rs2_val := emu_read_reg(e, int(instr.r_type.rs2))&0x3f

                result: u64
                switch instr.r_type.funct_7 {
                    case 0b0000000: {
                        result = rs1_val >> rs2_val

                        fmt.printf(" - srl x%d, x%d, x%d\n", instr.r_type.rd, instr.r_type.rs1, instr.r_type.rs2)
                    }
                    case 0b0100000: {
                        result = u64(i64(rs1_val) >> rs2_val)

                        fmt.printf(" - sra x%d, x%d, x%d\n", instr.r_type.rd, instr.r_type.rs1, instr.r_type.rs2)
                    }
                    case 0b0000001: {
                        result = rs1_val / rs2_val

                        fmt.printf(" - divu x%d, x%d, x%d\n", instr.r_type.rd, instr.r_type.rs1, instr.r_type.rs2)
                    }
                    case: {
                        return 0, false
                    }
                }

                emu_write_reg(e, int(instr.r_type.rd), result)

                return 4, true
            }
            case 0b110: {}
            case 0b111: {
                rs1_val := emu_read_reg(e, int(instr.r_type.rs1))
                rs2_val := emu_read_reg(e, int(instr.r_type.rs2))

                fmt.printf(" - and x%d, x%d, x%d\n", instr.r_type.rd, instr.r_type.rs1, instr.r_type.rs2)

                result: u64
                switch instr.r_type.funct_7 {
                    case 0b0000000: {
                        result = rs1_val & rs2_val

                        fmt.printf(" - and x%d, x%d, x%d\n", instr.r_type.rd, instr.r_type.rs1, instr.r_type.rs2)
                    }
                    case 0b0000001: {
                        result = rs1_val % rs2_val

                        fmt.printf(" - remu x%d, x%d, x%d\n", instr.r_type.rd, instr.r_type.rs1, instr.r_type.rs2)
                    }
                    case: {
                        return 0, false
                    }
                }

                emu_write_reg(e, int(instr.r_type.rd), result)

                return 4, true
            }
        }

        fmt.printf("\n")
    }
    else if instr.opcode.v == OP_ARITHMETIC_64_GROUP {
        // R-Type
        fmt.printf(" - OP_ARITHMETIC_64_GROUP 0b%3b", instr.i_type.funct_3)

        switch instr.i_type.funct_3 {
            case 0b000: {
                rs1_i32 := i32(emu_read_reg(e, int(instr.i_type.rs1))&0xFFFFFFFF)
                imm_i32 := i32(sign_extend_u16(instr.i_type.imm, 12))

                result := u64(i64(rs1_i32 + imm_i32))

                fmt.printf(" - addiw x%d, x%d, 0x%x\n", instr.i_type.rd, instr.i_type.rs1, imm_i32)

                emu_write_reg(e, int(instr.i_type.rd), result)

                return 4, true
            }
            case 0b001: {}
            case 0b010: {}
            case 0b011: {
            }
            case 0b100: {}
            case 0b101: {}
            case 0b110: {}
            case 0b111: {}
        }

        fmt.printf("\n")
    }
    else if instr.opcode.v == OP_BRANCH_GROUP {
        // B-Type
        fmt.printf(" - BRANCH GROUP 0b%3b", instr.b_type.funct_3)

        // Unscramble (imm_hi[12|10:5], imm_lo[4:1|11])
        imm_lo: = unscramble_imm(u32(instr.b_type.imm_lo), { 4,3,2,1,11 })
        imm_hi: = unscramble_imm(u32(instr.b_type.imm_hi), { 12,10,9,8,7,6,5 })

        imm := u16(imm_hi | imm_lo)

        rs1_val := emu_read_reg(e, int(instr.b_type.rs1))
        rs2_val := emu_read_reg(e, int(instr.b_type.rs2))

        offset := i32(sign_extend_u16(imm, 13))

        switch instr.b_type.funct_3 {
            case 0b000: {
                fmt.printf(" - beq x%d, x%d, 0x%x\n", instr.b_type.rs1, instr.b_type.rs2, offset)

                if i64(rs1_val) == i64(rs2_val) {
                    return emu_instr_jump_rel(e, offset)
                }
            }
            case 0b001: {
                fmt.printf(" - bne x%d, x%d, 0x%x\n", instr.b_type.rs1, instr.b_type.rs2, offset)

                if i64(rs1_val) != i64(rs2_val) {
                    return emu_instr_jump_rel(e, offset)
                }
            }
            case 0b100: {
                fmt.printf(" - blt x%d, x%d, 0x%x\n", instr.b_type.rs1, instr.b_type.rs2, offset)

                if i64(rs1_val) < i64(rs2_val) {
                    return emu_instr_jump_rel(e, offset)
                }
            }
            case 0b101: {
                fmt.printf(" - bge x%d, x%d, 0x%x\n", instr.b_type.rs1, instr.b_type.rs2, offset)
                if i64(rs1_val) >= i64(rs2_val) {
                    return emu_instr_jump_rel(e, offset)
                }
            }
            case 0b110: {
                fmt.printf(" - bltu x%d, x%d, 0x%x\n", instr.b_type.rs1, instr.b_type.rs2, offset)

                if rs1_val < rs2_val {
                    return emu_instr_jump_rel(e, offset)
                }
            }
            case 0b111: {
                fmt.printf(" - bgeu x%d, x%d, 0x%x\n", instr.b_type.rs1, instr.b_type.rs2, offset)

                if rs1_val >= rs2_val {
                    return emu_instr_jump_rel(e, offset)
                }
            }
        }

        return 4, true
    }
    else if instr.opcode.v == OP_STORE_GROUP {
        // S-Type
        rs1_val := i64(emu_read_reg(e, int(instr.s_type.rs1)))

        imm := i64(sign_extend_u32((u32(instr.s_type.imm_hi)<<5) | u32(instr.s_type.imm_lo), 12))
        addr := u64(rs1_val + imm)

        rs2_val := emu_read_reg(e, int(instr.s_type.rs2))

        switch instr.s_type.funct_3 {
            case 0b000: {
                fmt.printf(" - sb x%d, x%d, 0x%x\n", instr.s_type.rs1, instr.s_type.rs2, imm)
                emu_write_u8(e, addr, u8(rs2_val&0xFF))
            }
            case 0b001: {
                fmt.printf(" - sh x%d, x%d, 0x%x\n", instr.s_type.rs1, instr.s_type.rs2, imm)
                emu_write_u16(e, addr, u16(rs2_val&0xFFFF))
            }
            case 0b010: {
                fmt.printf(" - sw x%d, x%d, 0x%x\n", instr.s_type.rs1, instr.s_type.rs2, imm)
                emu_write_u32(e, addr, u32(rs2_val&0xFFFFFFFF))
            }
            case 0b011: {
                fmt.printf(" - sd x%d, x%d, 0x%x\n", instr.s_type.rs1, instr.s_type.rs2, imm)
                emu_write_u64(e, addr, rs2_val)
            }
        }

        return 4, true
    } else if instr.opcode.v == OP_ECALL {
        fmt.println(" - ECALL")

        // a7 (x15) syscall id
        // a0-a? (x8-x?) arguments

        SYS_TRAP    :: 0xFF
        SYS_PRINTLN :: 0xA

        SYS_LINUX_WRITE :: 0x40

        sys_call_id := emu_read_reg(e, 17)

        switch sys_call_id {
            case SYS_TRAP: {
                trap_code := emu_read_reg(e, 10)

                fmt.eprintf("\n\nTRAP: 0x%x\n\n", trap_code)
                return 0, false
            }
            case SYS_LINUX_WRITE:  {
                fd := emu_read_reg(e, 10)
                buf := emu_read_reg(e, 11)
                count := emu_read_reg(e, 12)

                fmt.printf("0x%x: %v\n", buf, count)

                str_buf := make([]u8, count, allocator = context.temp_allocator)

                for i in 0..<count {
                    str_buf[i] = emu_read_u8(e, buf+i)
                }

                str := string(str_buf)

                fmt.eprintf("%v", str)
                // fmt.eprintf("\nSYS_LINUX_WRITE: %v\n\n", str)

                emu_write_reg(e, 10, count)
            }
            case SYS_PRINTLN: {
                str_addr := emu_read_reg(e, 10)
                str_len := emu_read_reg(e, 11)

                // fmt.printf("0x%x: %v", str_addr, str_len)

                str_buf := make([]u8, str_len, allocator = context.temp_allocator)

                for i in 0..<str_len {
                    str_buf[i] = emu_read_u8(e, str_addr+i)
                }

                str := string(str_buf)

                fmt.eprintf("%v", str)
                // fmt.eprintf("\nSYS_PRINTLN: %v\n\n", str)
            }
            case: {
                fmt.eprintf("\nInvalid SYSCALL 0x%x\n\n", sys_call_id)
                emu_write_reg(e, 10, 0xFEFEFEFEFEFEFEFE)
            }
        }

        return 4, true
    }


    // if instr.opcode.v == 0b0010111 {
    //     input_1 := (instr>>7)&0x1F // 5bit operand
    //     input_2 := (instr>>12)&0x14 // 20bit operand

    //     result := e.pc + (u64(input_2)<<12)

    //     fmt.printf(" - auipc x%d <- (0x%0x)\n", input_1, result)

    //     emu_write_reg(e, int(input_1), result)

    //     return 4, true
    // }

    return
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

emu_do_rvc_q0 :: proc(e: ^Emu64, instr: u16) -> (pc_offset: u64, cont: bool) {
    suffix := instr>>13
    fmt.printf(" - 0b%3b", suffix)

    switch suffix {
        case 0b000: {
            rd := (instr>>2)&0b111
            imm_scrambled := u32((instr>>5) & 0xFF) // 8bit

            if imm_scrambled == 0 do return 2, false

            // Unscramble (imm[5:4|9:6|2|3])
            imm: u64 = u64(unscramble_imm(imm_scrambled, { 5,4,9,8,7,6,2,3 }))

            // FIXME
            imm_64 := imm//*4

            stack_reg_value := emu_read_reg(e, REG_X2)
            stack_reg_value += imm_64

            fmt.printf(" - c.addi4spn x%d, 0x%x (result: 0x%x)\n", rd+8, imm_64, stack_reg_value)

            emu_write_reg_cext(e, int(rd), stack_reg_value)

            return 2, true
        }
        case 0b001: {}
        case 0b010: {
            rd := (instr>>2)&0b111
            rs1 := (instr>>7)&0b111

            imm_1 := (instr>>5)&0b11
            imm_2 := (instr>>10)&0b111

            // FIXME
            imm := u64(((imm_1&0x1)<<6) | ((imm_1&0b10)<<1) | (imm_2<<3))

            reg_value := emu_read_reg_cext(e, int(rs1))
            addr := reg_value + imm

            value := i64(i32(emu_read_u32(e, addr)))

            // FIXME2 might need to only replace the 32 lower bits
            emu_write_reg_cext(e, int(rd), u64(value))

            fmt.printf(" - c.lw x%d, x%d 0x%x\n", rd+8, rs1+8, imm)

            return 2, true
        }
        case 0b011: {
            rd := (instr>>2)&0b111
            rs1 := (instr>>7)&0b111

            imm_lo := (instr>>10)&0b111
            imm_hi := (instr>>5)&0b11

            // FIXME
            imm := u64((imm_hi << 6) | (imm_lo << 3))//*8

            reg_value := emu_read_reg_cext(e, int(rs1))
            addr := reg_value + imm

            value := emu_read_u64(e, addr)

            emu_write_reg_cext(e, int(rd), value)

            fmt.printf(" - c.ld x%d, x%d 0x%x\n", rd+8, rs1+8, imm)

            return 2, true
        }
        case 0b100: {
            input_1 := (instr>>2)&0x1F // 5bit operand
            input_2 := (instr>>7)&0x1F // 5bit operand

            bit_12 := (instr&0x1000) > 0

            fmt.printf(" - 0x%x 0x%x %d", input_1, input_2, bit_12)

            if bit_12 {

            } else {
                if input_1 == 0 {
                    // C.JR
                    dst := emu_read_reg(e, int(input_2))

                    fmt.printf(" - c.jr x%d (0x%x)\n", input_2, dst)

                    return emu_instr_jump(e, dst)
                }
            }
        }
        case 0b101: {
        }
        case 0b110: {}
        case 0b111: {
            rs1 := (instr>>7)&0b111 // 3bit
            rs2 := (instr>>2)&0b111 // 3bit
            // FIXME
            imm := u64(((instr<<1)&0xC0) | ((instr>>7)&0x38))//*8

            addr := emu_read_reg_cext(e, int(rs1)) + imm

            fmt.printf(" - c.sd x%d, x%d (0x%x)\n", rs2, rs1, imm)

            emu_write_u64(e, addr, emu_read_reg_cext(e, int(rs2)))

            return 2, true
        }
    }

    return
}

emu_do_rvc_q1 :: proc(e: ^Emu64, instr: u16) -> (pc_offset: u64, cont: bool) {
    suffix := instr>>13
    fmt.printf(" - 0b%3b", suffix)

    switch suffix {
        case 0b000: {
            rd := (instr>>7)&0x1F // 5 bit

            imm_lo := (instr>>2)&0x1F
            imm_hi := (instr>>12)&0b1

            imm := (imm_hi << 5) | imm_lo

            if imm == 0 && rd == 0 {
                fmt.printf(" - c.nop\n")
                return 2, true
            }

            imm_extended := i64(sign_extend_u16(imm, 6))
            reg_value := i64(emu_read_reg(e, int(rd)))
            value := reg_value + imm_extended

            fmt.printf(" - c.addi x%d 0x%x (result: 0x%x)\n", rd, imm_extended, value)

            emu_write_reg(e, int(rd), u64(value))

            return 2, true
        }
        case 0b001: {
            rd := (instr>>7)&0x1F // 5 bit

            imm_lo := (instr>>2)&0x1F
            imm_hi := (instr>>12)&0b1

            imm := (imm_hi << 5) | imm_lo

            if imm == 0 && rd == 0 {
                fmt.printf(" - c.nop\n")
                return 2, true
            }

            imm_extended := i32(sign_extend_u16(imm, 6))
            reg_value := i32(emu_read_reg(e, int(rd))&0xFFFFFFFF)
            value := reg_value + imm_extended

            fmt.printf(" - c.addiw x%d 0x%x (result: 0x%x)\n", rd, imm_extended, value)

            emu_write_reg(e, int(rd), u64(i64(value)))

            return 2, true
        }
        case 0b010: {
            rd := (instr>>7)&0x1F // 5bit

            if rd != 0 {
                imm := i64(sign_extend_u16(((instr>>2)&0x1F) | ((instr>>12)&1)<<5, 6)) // 5bit

                fmt.printf(" - c.li x%v, 0x%x\n", rd, u64(imm))

                emu_write_reg(e, int(rd), u64(imm))
            }

            return 2, true
        }
        case 0b011: {
            rd := (instr>>7)&0x1F // 5bit

            if rd == 2 {
                imm_scrambled := u32((instr>>2) & 0x1F) // 8bit
                imm_12 := u32((instr>>12)&0x1)

                // Unscramble (imm[4|6|8:7|5])
                imm: = u32(unscramble_imm(imm_scrambled, { 4,6,8,7,5 }))
                imm |= (imm_12<<9)

                if imm == 0 do return 2, true

                // FIXME
                imm_64 := i64(sign_extend_u32(imm, 10))//*16

                stack_reg_value := i64(emu_read_reg(e, REG_X2))
                stack_reg_value += imm_64

                fmt.printf(" - c.addi16sp x%d, 0x%x (result: 0x%x)\n", rd, u64(imm_64), u64(stack_reg_value))

                emu_write_reg(e, int(rd), u64(stack_reg_value))

                return 2, true
            } else if rd != 0 {
                imm_1 := (instr>>2)&0x1F // 5bit
                imm_2 := (instr>>12)&0x1 // 1bit

                imm := i64(sign_extend_u32((u32(imm_1)<<12) | (u32(imm_2)<<17), 18))

                fmt.printf(" - c.lui x%v, 0x%x\n", rd, imm)

                emu_write_reg(e, int(rd), u64(imm))
            }

            return 2, true
        }
        case 0b100: {
            bit_12 := (instr&0x1000) > 0
            funct_1 := (instr>>5)&0b11
            funct_2 := (instr>>10)&0b11

            fmt.printf(" - bit12 %v f2 0b%2b f1 0b%2b", bit_12, funct_2, funct_1)

            if bit_12 && funct_2 == 0b11 {
            } else {
                imm := (instr>>2)&0x1F  // 5bit
                rs2 := (instr>>2)&0b111 // 3bit
                rd := (instr>>7)&0b111  // 3bit

                switch funct_2 {
                    case 0b00: {
                        imm_extended := u64(imm | (((instr>>12)&0x1)<<5))
                        reg_value := emu_read_reg_cext(e, int(rd))

                        result := reg_value >> imm_extended

                        fmt.printf(" - c.srli x%v, 0x%x\n", rd+8, imm_extended)

                        emu_write_reg_cext(e, int(rd), result)

                        return 2, true
                    }
                    case 0b01: {
                        imm_extended := u64(imm | (((instr>>12)&0x1)<<5))
                        reg_value := emu_read_reg_cext(e, int(rd))

                        result := i64(reg_value) >> imm_extended

                        fmt.printf(" - c.srai x%v, 0x%x\n", rd+8, imm_extended)

                        emu_write_reg_cext(e, int(rd), u64(result))

                        return 2, true
                    }
                    case 0b10: {
                        // C.ANDI

                        imm_extended := i64(sign_extend_u16(imm | (((instr>>12)&0x1)<<5), 6))
                        reg_value := i64(emu_read_reg_cext(e, int(rd)))

                        result := reg_value & imm_extended

                        fmt.printf(" - c.andi x%v, 0x%x\n", rd+8, imm_extended)

                        emu_write_reg_cext(e, int(rd), u64(result))

                        return 2, true
                    }
                    case 0b11: {
                        switch funct_1 {
                            case 0b00: {
                                rs2_val := emu_read_reg_cext(e, int(rs2))
                                rd_val := emu_read_reg_cext(e, int(rd))

                                rd_val -= rs2_val

                                fmt.printf(" - c.sub x%v, x%v\n", rd+8, rs2+8)

                                emu_write_reg_cext(e, int(rd), rd_val)

                                return 2, true
                            }
                            case 0b01: {
                                rs2_val := emu_read_reg_cext(e, int(rs2))
                                rd_val := emu_read_reg_cext(e, int(rd))

                                rd_val ~= rs2_val

                                fmt.printf(" - c.xor x%v, x%v\n", rd+8, rs2+8)

                                emu_write_reg_cext(e, int(rd), rd_val)

                                return 2, true
                            }
                            case 0b10: {
                                rs2_val := emu_read_reg_cext(e, int(rs2))
                                rd_val := emu_read_reg_cext(e, int(rd))

                                rd_val |= rs2_val

                                fmt.printf(" - c.or x%v, x%v\n", rd+8, rs2+8)

                                emu_write_reg_cext(e, int(rd), rd_val)

                                return 2, true
                            }
                            case 0b11: {
                                rs2_val := emu_read_reg_cext(e, int(rs2))
                                rd_val := emu_read_reg_cext(e, int(rd))

                                rd_val &= rs2_val

                                fmt.printf(" - c.and x%v, x%v\n", rd+8, rs2+8)

                                emu_write_reg_cext(e, int(rd), rd_val)

                                return 2, true
                            }
                        }
                    }
                }
            }
        }
        case 0b101: {
            // C.J (Unconditional Jump)
            imm := u32((instr>>2) & 0x7FF) // 10bit immediate

            // Unscramble (imm[11|4|9:8|10|6|7|3:1|5])
            offset: = sign_extend_u32(unscramble_imm(imm, { 11,4,9,8,10,6,7,3,2,1,5 }), 12)

            fmt.printf(" - c.j 0x%x\n", offset)

            return emu_instr_jump_rel(e, offset)
        }
        case 0b110: {
            rs1 := (instr>>7)&0b111

            imm_lo: = unscramble_imm(u32((instr>>2)&0x1F),   { 7,6,2,1,5 })
            imm_hi: = unscramble_imm(u32((instr>>10)&0b111), { 8,4,3 })

            imm := imm_hi | imm_lo

            offset := i32(sign_extend_u32(imm, 9))

            fmt.printf(" - c.beqz x%x (0x%x)\n", rs1, offset)

            if emu_read_reg_cext(e, int(rs1)) == 0 {
                return emu_instr_jump_rel(e, offset)
            }

            return 2, true
        }
        case 0b111: {
            rs1 := (instr>>7)&0b111

            imm_lo: = unscramble_imm(u32((instr>>2)&0x1F),   { 7,6,2,1,5 })
            imm_hi: = unscramble_imm(u32((instr>>10)&0b111), { 8,4,3 })

            imm := imm_hi | imm_lo

            offset := i32(sign_extend_u32(imm, 9))

            fmt.printf(" - c.bnez x%x (0x%x)\n", rs1, offset)

            if emu_read_reg_cext(e, int(rs1)) != 0 {
                return emu_instr_jump_rel(e, offset)
            }

            return 2, true
        }
    }

    return
}

emu_do_rvc_q2 :: proc(e: ^Emu64, instr: u16) -> (pc_offset: u64, cont: bool) {
    suffix := instr>>13
    fmt.printf(" - 0b%3b", suffix)

    switch suffix {
        case 0b000: {
            rd := (instr>>7)&0x1F // 5bit
            imm := u64((instr>>2)&0x1F | (((instr>>12)&0b1)<<5))

            if rd == 0 do return 2, true

            reg_value := emu_read_reg(e, int(rd))
            reg_value = reg_value << imm

            fmt.printf(" - c.slli x%d, 0x%x\n", int(rd), imm)

            emu_write_reg(e, int(rd), reg_value)

            return 2, true
        }
        case 0b001: {}
        case 0b010: {
            rd := (instr>>7)&0x1F // 5bit
            imm_1 := u32((instr>>2)&0x1F) // 5bit
            imm_2 := u32((instr>>12)&0x1) // 1bit

            if rd == 0 do return 2, true

            // FIXME: is this necessary? is it already scaled by 8?
            // Unscramble the encoding (offset[4:2|7:6])
            imm: = u64(unscramble_imm(imm_1, { 4,3,2,7,6 }))
            imm |= u64(imm_2)<<5

            imm = imm//*8

            addr := imm + emu_read_reg(e, REG_X2)

            fmt.printf(" - c.lwsp x%d (0x%x)\n", rd, imm)

            // FIXME: sign extended?
            value := i64(i32(emu_read_u32(e, addr)))
            emu_write_reg(e, int(rd), u64(value))

            return 2, true
        }
        case 0b011: {
            rd := (instr>>7)&0x1F // 5bit
            imm_1 := u32((instr>>2)&0x1F) // 5bit
            imm_2 := u32((instr>>12)&0x1) // 1bit

            if rd == 0 do return 2, true

            // FIXME: is this necessary? is it already scaled by 8?
            // Unscramble the encoding (offset[4:3|8:6])
            imm: = u64(unscramble_imm(imm_1, { 4,3,8,7,6 }))
            imm |= u64(imm_2)<<5

            imm = imm//*8

            addr := imm + emu_read_reg(e, REG_X2)

            fmt.printf(" - c.ldsp x%d (0x%x)\n", rd, imm)

            value := emu_read_u64(e, addr)
            emu_write_reg(e, int(rd), value)

            return 2, true
        }
        case 0b100: {
            input_1 := (instr>>2)&0x1F // 5bit operand
            input_2 := (instr>>7)&0x1F // 5bit operand

            bit_12 := (instr&0x1000) > 0

            if bit_12 {
                if input_2 != 0 {
                    if input_1 == 0 {
                        reg := emu_read_reg(e, int(input_2))

                        emu_write_reg(e, int(1), e.pc+2)
                        e.pc = reg

                        fmt.printf(" - c.jalr x%d\n", input_2)

                        return 0, true
                    } else {
                        rs2_val := emu_read_reg(e, int(input_1))
                        rd_val := emu_read_reg(e, int(input_2))

                        rd_val += rs2_val

                        fmt.printf(" - c.add x%d, x%d\n", input_2, input_1)

                        emu_write_reg(e, int(input_2), rd_val)

                        return 2, true
                    }
                } else {

                }
            } else {
                if input_1 == 0 {
                    // C.JR
                    dst := emu_read_reg(e, int(input_2))

                    fmt.printf(" - c.jr x%d (0x%x)\n", input_2, dst)

                    return emu_instr_jump(e, dst)
                } else if input_1 != 0 && input_2 != 0 {
                    fmt.printf(" - c.mv x%d x%d\n", input_2, input_1)

                    emu_write_reg(e, int(input_2), emu_read_reg(e, int(input_1)))

                    return 2, true
                }
            }
        }
        case 0b101: {}
        case 0b110: {
            rs2   := (instr>>2)&0x1F // 5bit
            imm_1 := u32((instr>>7)&0x3F) // 6bit

            // Unscramble the encoding (offset[5:2|8:6])
            imm: = u64(unscramble_imm(imm_1, { 5,4,3,2,7,6 }))

            addr := imm + emu_read_reg(e, REG_X2)

            fmt.printf(" - c.swsp x%d (0x%x)\n", rs2, addr)

            emu_write_u32(e, addr, u32(emu_read_reg(e, int(rs2))&0xFFFFFFFF))

            return 2, true
        }
        case 0b111: {
            rs2   := (instr>>2)&0x1F // 5bit
            imm_1 := u32((instr>>7)&0x3F) // 6bit

            // FIXME: is this necessary? is it already scaled by 8?
            // Unscramble the encoding (offset[5:3|8:6])
            imm: = u64(unscramble_imm(imm_1, { 5,4,3,8,7,6 }))//*8

            addr := imm + emu_read_reg(e, REG_X2)
            reg_value := emu_read_reg(e, int(rs2))

            fmt.printf(" - c.sdsp x%d (0x%x)\n", rs2, imm)

            emu_write_u64(e, addr, reg_value)

            return 2, true
        }
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

emu_do_load_instr :: proc(e: ^Emu64, instr: EmuInstructionIType32) -> (pc_offset: u64, cont: bool) {
    fmt.printf(" - LOAD Group 0b%3b", instr.funct_3)

    rs1_val := i64(emu_read_reg(e, int(instr.rs1)))

    imm := i64(sign_extend_u16(instr.imm, 12))
    addr := u64(rs1_val + imm)

    switch instr.funct_3 {
        case 0b000: {
            value := i64(i8(emu_read_u8(e, addr)))
            fmt.printf(" - lb x%d, x%d, 0x%x\n", instr.rd, instr.rs1, imm)
            emu_write_reg(e, int(instr.rd), u64(value))
        }
        case 0b001: {
            value := i64(i16(emu_read_u16(e, addr)))
            fmt.printf(" - lh x%d, x%d, 0x%x\n", instr.rd, instr.rs1, imm)
            emu_write_reg(e, int(instr.rd), u64(value))
        }
        case 0b010: {
            value := i64(i32(emu_read_u32(e, addr)))
            fmt.printf(" - lw x%d, x%d, 0x%x\n", instr.rd, instr.rs1, imm)
            emu_write_reg(e, int(instr.rd), u64(value))
        }
        case 0b011: {
            value := emu_read_u64(e, addr)
            fmt.printf(" - ld x%d, x%d, 0x%x\n", instr.rd, instr.rs1, imm)
            emu_write_reg(e, int(instr.rd), value)
        }
        case 0b100: {
            value := u64(emu_read_u8(e, addr))
            fmt.printf(" - lbu x%d, x%d, 0x%x\n", instr.rd, instr.rs1, instr.imm)
            emu_write_reg(e, int(instr.rd), value)
        }
        case 0b101: {
            value := u64(emu_read_u16(e, addr))
            fmt.printf(" - lhu x%d, x%d, 0x%x\n", instr.rd, instr.rs1, instr.imm)
            emu_write_reg(e, int(instr.rd), value)
        }
    }

    return 4, true
}

emu_do_signed_arithmetic_instr :: proc(e: ^Emu64, instr: EmuInstructionIType32) -> (pc_offset: u64, cont: bool) {

    fmt.printf(" - Arithmetic Group 0b%3b", instr.funct_3)

    switch instr.funct_3 {
        case 0b000: {
            rs1_val := emu_read_reg(e, int(instr.rs1))

            result := i64(rs1_val) + i64(i16(sign_extend_u16(instr.imm, 12)))

            fmt.printf(" - addi x%d, x%d, 0x%x\n", instr.rd, instr.rs1, instr.imm)

            emu_write_reg(e, int(instr.rd), u64(result))

            return 4, true
        }
        case 0b001: {
            rs1_val := emu_read_reg(e, int(instr.rs1))
            shamt := u64((instr.imm&0x3f))

            result := rs1_val << shamt

            fmt.printf(" - slli x%d, x%d, 0x%x\n", instr.rd, instr.rs1, shamt)

            emu_write_reg(e, int(instr.rd), result)

            return 4, true
        }
        case 0b010: {
            rs1_val := emu_read_reg(e, int(instr.rs1))
            imm := i64(i16(sign_extend_u16(instr.imm, 12)))

            fmt.printf(" - slti x%d, x%d, 0x%x\n", instr.rd, instr.rs1, instr.imm)

            if i64(rs1_val) < imm {
                emu_write_reg(e, int(instr.rd), 1)
            } else {
                emu_write_reg(e, int(instr.rd), 0)
            }

            return 4, true
        }
        case 0b011: {
            rs1_val := emu_read_reg(e, int(instr.rs1))
            imm := u64(i64(i16(sign_extend_u16(instr.imm, 12))))

            fmt.printf(" - sltiu x%d, x%d, 0x%x\n", instr.rd, instr.rs1, instr.imm)

            if rs1_val < imm {
                emu_write_reg(e, int(instr.rd), 1)
            } else {
                emu_write_reg(e, int(instr.rd), 0)
            }

            return 4, true
        }
        case 0b100: {
            rs1_val := emu_read_reg(e, int(instr.rs1))
            imm := i64(i16(sign_extend_u16(instr.imm, 12)))

            fmt.printf(" - xori x%d, x%d, 0x%x\n", instr.rd, instr.rs1, instr.imm)

            result := i64(rs1_val) ~ imm

            emu_write_reg(e, int(instr.rd), u64(result))

            return 4, true
        }
        case 0b101: {
            rs1_val := emu_read_reg(e, int(instr.rs1))
            shamt := u64((instr.imm&0x3f))

            if ((instr.imm>>10)&1) > 0 {
                result := i64(rs1_val) >> shamt

                fmt.printf(" - srai x%d, x%d, 0x%x\n", instr.rd, instr.rs1, shamt)

                emu_write_reg(e, int(instr.rd), u64(result))
            } else {
                result := rs1_val >> shamt

                fmt.printf(" - srli x%d, x%d, 0x%x\n", instr.rd, instr.rs1, shamt)

                emu_write_reg(e, int(instr.rd), result)
            }

            return 4, true
        }
        case 0b110: {
            rs1_val := emu_read_reg(e, int(instr.rs1))
            imm := i64(i16(sign_extend_u16(instr.imm, 12)))

            fmt.printf(" - ori x%d, x%d, 0x%x\n", instr.rd, instr.rs1, instr.imm)

            result := i64(rs1_val) | imm

            emu_write_reg(e, int(instr.rd), u64(result))

            return 4, true
        }
        case 0b111: {
            rs1_val := emu_read_reg(e, int(instr.rs1))
            imm := i64(i16(sign_extend_u16(instr.imm, 12)))

            fmt.printf(" - andi x%d, x%d, 0x%x\n", instr.rd, instr.rs1, instr.imm)

            result := i64(rs1_val) & imm

            emu_write_reg(e, int(instr.rd), u64(result))

            return 4, true
        }
    }

    return
}

@(test)
sign_extend_Test :: proc(t: ^testing.T) {

    num_7bit: u8 = 0b00111110 // -2 in 7bit 2's compliment

    num_8bit_signed := sign_extend_u8(num_7bit, 6)

    num_16bit_signed := i16(num_8bit_signed)

    testing.expect_value(t, num_8bit_signed, -2)
    testing.expect_value(t, num_16bit_signed, -2)
}

