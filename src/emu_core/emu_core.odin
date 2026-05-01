package emu_core

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
    _zero:     u8 | 1,
    imm_lo:    u8 | 4,
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
        page_table = emu_make_page_table(1024 * 4),
    }
}

emu_make_page_table :: proc(page_size: u64, allocator := context.allocator) -> EmuPageTable {
    assert(page_size%8 == 0)

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

emu_load_elf :: proc(e: ^Emu64, file_path: string) -> (ok: bool) {
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

    e.pc = entry_point_addr

    return true
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
    assert(offset+8 < u64(len(page.virtual_mem)), "u64 crosses page boundary")

    return u64((transmute(^u64)(&page.virtual_mem[offset]))^)
}

emu_read_u32 :: proc(e: ^Emu64, vaddr: u64, loc := #caller_location) -> u32 {
    page := emu_get_page(e, vaddr)
    assert(page != nil, "no page found")

    offset := vaddr - page.start_addr
    assert(offset+4 < u64(len(page.virtual_mem)), "u32 crosses page boundary")

    return u32((transmute(^u32)(&page.virtual_mem[offset]))^)
}

emu_read_u16 :: proc(e: ^Emu64, vaddr: u64, loc := #caller_location) -> u16 {
    page := emu_get_page(e, vaddr)
    assert(page != nil, "no page found")

    offset := vaddr - page.start_addr
    assert(offset+2 < u64(len(page.virtual_mem)), "u16 crosses page boundary")

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
    assert(offset+8 < u64(len(page.virtual_mem)), "u64 crosses page boundary")

    for i in 0..<8 {
        page.virtual_mem[int(offset)+i] = u8((value>>(uint(i)*8))&0xFF)
    }
}

emu_write_u32 :: proc(e: ^Emu64, vaddr: u64, value: u32) {
    page := emu_get_page(e, vaddr)
    assert(page != nil, "no page found")

    offset := vaddr - page.start_addr
    assert(offset+4 < u64(len(page.virtual_mem)), "u32 crosses page boundary")

    for i in 0..<4 {
        page.virtual_mem[int(offset)+i] = u8((value>>(uint(i)*8))&0xFF)
    }
}

emu_write_u16 :: proc(e: ^Emu64, vaddr: u64, value: u16) {
    page := emu_get_page(e, vaddr)
    assert(page != nil, "no page found")

    offset := vaddr - page.start_addr
    assert(offset+2 < u64(len(page.virtual_mem)), "u16 crosses page boundary")

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

emu_run_interactive :: proc(e: ^Emu64) {
    e.running = true

    for e.running {
        instruction_lo := emu_read_u16(e, e.pc)

        prefix := instruction_lo&0b11

        fmt.eprintf("Running instruction at 0x%16x: 0x%4x (0b%16b) opcode: 0b%7b", e.pc, instruction_lo, instruction_lo, instruction_lo&0b1111111)

        old_pc := e.pc

        switch prefix {
            case 0b00: {
                fmt.eprintf(" - RVC (Q0)")
                offset, cont := emu_do_rvc_q0(e, instruction_lo)

                e.running = cont
                e.pc += offset
            }
            case 0b01: {
                fmt.eprintf(" - RVC (Q1)")
                offset, cont := emu_do_rvc_q1(e, instruction_lo)

                e.running = cont
                e.pc += offset
            }
            case 0b10: {
                fmt.eprintf(" - RVC (Q2)")
                offset, cont := emu_do_rvc_q2(e, instruction_lo)

                e.running = cont
                e.pc += offset
            }

            // >16b
            case 0b11: {
                fmt.eprintf(" - RV32/64")
                offset, cont := emu_do_rv64(e)

                e.running = cont
                e.pc += offset
            }
        }

        for bp in e.break_points {
            if bp == old_pc {
                e.running = false
                fmt.eprintln("\nHit Breakpoint")
                break
            }
        }

        fmt.eprintf("regs: %x\n", e.reg)
    }
}

emu_do_rv64 :: proc(e: ^Emu64) -> (pc_offset: u64, cont: bool) {
    OP_JAL                     :: 0b1101111
    OP_JALR                    :: 0b1100111

    OP_LUI                     :: 0b0110111
    OP_AUIPC                   :: 0b0010111

    OP_ARITHMETIC_GROUP        :: 0b0110011
    OP_ARITHMETIC_64_GROUP        :: 0b0011011
    OP_BRANCH_GROUP            :: 0b1100011
    OP_STORE_GROUP             :: 0b0100011

    OP_SIGNED_ARITHMETIC_GROUP :: 0b0010011

    OP_ECALL                   :: 0b1110011

    instr := EmuInstruction32{}
    instr.raw_instruction = emu_read_u32(e, e.pc)

    if instr.opcode.v == OP_JAL {
        // J-Type
        imm_32 := (u32(instr.j_type.imm_hi) << 12) | (u32(instr.j_type.imm_lo) << 1) | (u32(instr.j_type.imm_mid) << 11) | (u32(instr.j_type.imm_msb) << 20)

        imm := sign_extend_u32(imm_32, 20)

        fmt.printf(" - jal x%d, 0x%x\n", instr.j_type.rd, imm)

        emu_write_reg(e, int(instr.j_type.rd), e.pc + 4)
        return emu_instr_jump_rel(e, imm)
    }
    else if instr.opcode.v == OP_LUI {
        // U-Type
        imm := i64(instr.u_type.imm << 12)

        fmt.printf(" - lui x%d, 0x%x\n", instr.u_type.rd, imm)

        emu_write_reg(e, int(instr.u_type.rd), u64(imm))

        return 4, true
    }
    else if instr.opcode.v == OP_AUIPC {
        // U-Type
        imm := i64(instr.u_type.imm<<12)

        result: u64
        if imm > 0 {
            result = e.pc + u64(imm)
        } else {
            result = e.pc + u64(-imm)
        }

        fmt.eprintf(" - auipc x%d <- (0x%x)\n", instr.u_type.rd, result)

        emu_write_reg(e, int(instr.u_type.rd), result)

        return 4, true
    }
    else if instr.opcode.v == OP_JALR || instr.opcode.v == 0b0000011 || instr.opcode.v == 0b0010011 {
        // I-Type or *R-Type

        if instr.opcode.v == 0b0010011 && (instr.r_type.funct_3 == 0b001 || instr.r_type.funct_3 == 0b101) {
            // *R-Type

            // TODO
            fmt.println(" - SLLI et al")
        } else {
            // I-Type

            // TODO
            fmt.printf(" - Load and Math")

            switch instr.opcode.v {
                case OP_JALR: {}
                case OP_SIGNED_ARITHMETIC_GROUP: {
                    return emu_do_signed_arithmetic_instr(e, instr.i_type)
                }
            }

            fmt.printf("\n")
        }
    }
    else if instr.opcode.v == OP_ARITHMETIC_GROUP || instr.opcode.v == OP_ARITHMETIC_64_GROUP {
        // R-Type
        fmt.printf(" - OP_ARITHMETIC_GROUP 0b%3b", instr.i_type.funct_3)

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
            case 0b011: {}
            case 0b100: {}
            case 0b101: {}
            case 0b110: {}
            case 0b111: {}
        }

        fmt.printf("\n")
    }
    else if instr.opcode.v == OP_BRANCH_GROUP {
        // B-Type
        fmt.println(" - OP_BRANCH_GROUP ")
    }
    else if instr.opcode.v == OP_STORE_GROUP {
        // S-Type
        fmt.println(" - OP_STORE_GROUP")
    } else if instr.opcode.v == OP_ECALL {
        fmt.println("ecall hahaha")

        // a7 (x15) syscall id
        // a0-a? (x8-x?) arguments
    }


    // if instr.opcode.v == 0b0010111 {
    //     input_1 := (instr>>7)&0x1F // 5bit operand
    //     input_2 := (instr>>12)&0x14 // 20bit operand

    //     result := e.pc + (u64(input_2)<<12)

    //     fmt.eprintf(" - auipc x%d <- (0x%0x)\n", input_1, result)

    //     emu_write_reg(e, int(input_1), result)

    //     return 4, true
    // }

    return
}

emu_do_rvc_q0 :: proc(e: ^Emu64, instr: u16) -> (pc_offset: u64, cont: bool) {
    suffix := instr>>13
    fmt.eprintf(" - 0b%3b", suffix)

    switch suffix {
        case 0b000: {}
        case 0b001: {}
        case 0b010: {}
        case 0b011: {
            rd := (instr>>2)&0b111
            rs1 := (instr>>7)&0b111

            imm_lo := (instr>>10)&0b111
            imm_hi := (instr>>5)&0b111

            imm := (imm_hi << 3) | imm_lo

            reg_value := emu_read_reg_cext(e, int(rs1))
            addr := reg_value + u64(imm)*8

            value := emu_read_u64(e, addr)

            emu_write_reg_cext(e, int(rd), value)

            fmt.eprintf(" - c.ld x%d, x%d 0x%x\n", rd+8, rs1+8, imm)

            return 2, true
        }
        case 0b100: {
            input_1 := (instr>>2)&0x1F // 5bit operand
            input_2 := (instr>>7)&0x1F // 5bit operand

            bit_12 := (instr&0x1000) > 0

            fmt.eprintf(" - 0x%x 0x%x %d", input_1, input_2, bit_12)

            if bit_12 {

            } else {
                if input_1 == 0 {
                    // C.JR
                    dst := emu_read_reg(e, int(input_2))

                    fmt.eprintf(" - c.jr x%d (0x%x)\n", input_2, dst)

                    emu_instr_jump(e, dst)

                    return 0, true
                }
            }
        }
        case 0b101: {
            // C.J (Unconditional Jump)
            imm := u64((instr>>2) & 0x7FF) // 10bit immediate

            // Unscramble (imm[11|4|9:8|10|6|7|3:1|5])
            addr: u64
            addr |= (imm&0x400)<<1  // 10  -> 11
            addr |= (imm&0x200)>>5  // 9   -> 4
            addr |= (imm&0x180)<<1  // 8:7 -> 9:8
            addr |= (imm&0x40)<<4   // 6   -> 10
            addr |= (imm&0x20)<<1   // 5   -> 6
            addr |= (imm&0x10)<<3   // 4   -> 7
                                    // 3:1 -> 3:1
            addr |= (imm&0x1)<<5    // 0   -> 5

            dst := e.pc+addr
            fmt.eprintf(" - c.j 0x%x (0x%x)\n", addr, dst)

            emu_instr_jump(e, dst)

            return 0, true
        }
        case 0b110: {}
        case 0b111: {}
    }

    return
}

emu_do_rvc_q1 :: proc(e: ^Emu64, instr: u16) -> (pc_offset: u64, cont: bool) {
    suffix := instr>>13
    fmt.eprintf(" - 0b%3b", suffix)

    switch suffix {
        case 0b000: {
            rd := (instr>>7)&0x1F // 5 bit

            // NOP: rd = 0
            if rd == 0 { return 2, true }

            imm_lo := (instr>>2)&0x1F
            imm_hi := (instr>>12)&0b1

            imm := (imm_hi << 5) | imm_lo

            if imm == 0 { return 2, true }

            imm_extended := i64(sign_extend_u16(imm, 6))
            reg_value := i64(emu_read_reg(e, int(rd)))
            value := reg_value + imm_extended

            fmt.eprintf(" - c.addi x%d 0x%x (result: 0x%x)\n", rd, imm_extended, value)

            emu_write_reg(e, int(rd), u64(value))

            return 2, true
        }
        case 0b001: {
            rd := (instr>>7)&0x1F

            if rd == 0 { return 2, true }
        }
        case 0b010: {
            return 2, true
        }
        case 0b011: {
            return 2, true
        }
        case 0b100: {
            bit_12 := (instr&0x1000) > 0
            funct_1 := (instr>>5)&0b11
            funct_2 := (instr>>10)&0b11

            fmt.eprintf(" - bit12 %v f2 0b%2b f1 0b%2b", bit_12, funct_2, funct_1)

            if bit_12 {
            } else {
                imm := (instr>>2)&0x1F  // 5bit
                rs2 := (instr>>2)&0b111 // 3bit
                rd := (instr>>7)&0b111  // 3bit

                switch funct_2 {
                    case 0b00: {}
                    case 0b01: {}
                    case 0b10: {}
                    case 0b11: {
                        switch funct_1 {
                            case 0b00: {}
                            case 0b01: {}
                            case 0b10: {
                                rs2_val := emu_read_reg_cext(e, int(rs2))
                                rd_val := emu_read_reg_cext(e, int(rd))

                                rd_val |= rs2_val

                                fmt.eprintf(" - c.or x%v, x%v\n", rd+8, rs2+8)

                                emu_write_reg_cext(e, int(rd), rd_val)

                                return 2, true
                            }
                            case 0b11: {}
                        }
                    }
                }
            }
        }
        case 0b101: {
            // C.J (Unconditional Jump)
            addr := u64((instr>>2) & 0x7FF) // 10bit immediate
            dst := e.pc+addr

            fmt.eprintf(" - c.j 0x%x (0x%x)\n", addr, dst)

            emu_instr_jump(e, dst)

            return 0, true
        }
        case 0b110: {}
        case 0b111: {}
    }

    return
}

emu_do_rvc_q2 :: proc(e: ^Emu64, instr: u16) -> (pc_offset: u64, cont: bool) {
    suffix := instr>>13
    fmt.eprintf(" - 0b%3b", suffix)

    switch suffix {
        case 0b000: {
            rd := (instr>>7)&0x1F // 5bit
            imm := u64((instr>>2)&0x1F | (instr>>12)&0b1)

            if rd == 0 { return 2, true }

            reg_value := emu_read_reg(e, int(rd))
            reg_value = reg_value << imm

            fmt.eprintf(" - c.slli x%d, 0x%x\n", int(rd), imm)

            emu_write_reg(e, int(rd), reg_value)

            return 2, true
        }
        case 0b001: {}
        case 0b010: {}
        case 0b011: {
            rd := (instr>>7)&0x1F // 5bit
            imm_1 := (instr>>2)&0x3F // 5bit
            imm_2 := (instr>>12)&0x1 // 1bit

            if rd == 0 { return 2, true }

            // FIXME: is this necessary? is it already scaled by 8?
            // Unscramble the encoding (offset[4:3|8:6])
            imm := ((imm_1&0x18) | ((imm_1&0b111) << 6)) | (imm_2 << 5)

            addr := u64(imm)*8 + emu_read_reg(e, REG_X2)

            fmt.eprintf(" - c.ldsp x%d (0x%x)\n", rd, imm)

            value := emu_read_u64(e, addr)
            emu_write_reg(e, int(rd), value)

            return 2, true
        }
        case 0b100: {
            input_1 := (instr>>2)&0x1F // 5bit operand
            input_2 := (instr>>7)&0x1F // 5bit operand

            bit_12 := (instr&0x1000) > 0

            if bit_12 {

            } else {
                if input_1 == 0 {
                    // C.JR
                    dst := emu_read_reg(e, int(input_2))

                    fmt.eprintf(" - c.jr x%d (0x%x)\n", input_2, dst)

                    return emu_instr_jump(e, dst)
                }
            }
        }
        case 0b101: {}
        case 0b110: {}
        case 0b111: {
            // C.SDSP is an RV64C-only instruction that stores a 64-bit value in register rs2 to memory. It computes an effective address by adding the zero-extended offset, scaled by 8, to the stack pointer, x2. It expands to sd rs2, offset(x2).

            rs2   := (instr>>2)&0x1F // 5bit
            imm_1 := (instr>>7)&0x3F // 6bit

            // FIXME: is this necessary? is it already scaled by 8?
            // Unscramble the encoding (offset[5:3|8:6])
            imm := ((imm_1&0x38) | ((imm_1&0b111) << 6))

            addr := u64(imm)*8 + emu_read_reg(e, REG_X2)
            reg_value := emu_read_reg(e, int(rs2))

            fmt.eprintf(" - c.sdsp x%d (0x%x)\n", rs2, imm)

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

emu_do_signed_arithmetic_instr :: proc(e: ^Emu64, instr: EmuInstructionIType32) -> (pc_offset: u64, cont: bool) {
    switch instr.funct_3 {
        case 0b000: {
            value := i64(sign_extend_u16(instr.imm, 12))
            reg_value := i64(emu_read_reg(e, int(instr.rs1)))
            result := value + reg_value

            fmt.eprintf(" - addi x%d, x%d, 0x%x (result: 0x%x)\n", instr.rd, instr.rs1, value, reg_value)

            emu_write_reg(e, int(instr.rd), u64(result))

            return 4, true
        }
        case 0b010: {}
        case 0b011: {}
        case 0b100: {}
        case 0b110: {}
        case 0b111: {}
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

