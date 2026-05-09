#include "stdlib.h"

#define SYS_TRAP 0xFF
#define SYS_PRINTLN 0x0A
#define SYS_CALL_HOST 0x0B

#define SYS_PUSH_STACK 0x02
#define SYS_POP_STACK 0x03

#define SYS_PUSH_FN_U32 0x01
#define SYS_PUSH_FN_POINTER 0x02
#define SYS_PUSH_FN_STRING 0x03

static void emu_trap(U16 code) {
  register U64 a7 asm("x17") = SYS_TRAP;
  register U64 a0 asm("x10") = (U64)code;

  asm volatile("ecall" : "+r"(a0) : "r"(a7) : "memory");
}

void emu_println(const U8 *buf, U64 len) {
  register U64 a7 asm("x17") = SYS_PRINTLN;
  register U64 a0 asm("x10") = (U64)buf;
  register U64 a1 asm("x11") = len;

  asm volatile("ecall" : "+r"(a0) : "r"(a1), "r"(a7) : "memory");
}

void emu_out_call_host_fn(const U8 *buf, U64 len) {
  register U64 a7 asm("x17") = SYS_CALL_HOST;
  register U64 a0 asm("x10") = (U64)buf;
  register U64 a1 asm("x11") = len;

  asm volatile("ecall" : "+r"(a0) : "r"(a1), "r"(a7) : "memory");
}

void emu_out_push_u32(U32 value) {
  register U64 a7 asm("x17") = SYS_PUSH_STACK;
  register U64 a0 asm("x10") = SYS_PUSH_FN_U32;
  register U32 a1 asm("x11") = value;

  asm volatile("ecall" : "+r"(a0) : "r"(a1), "r"(a7));
}
void emu_out_push_u64(U64 value) {
  register U64 a7 asm("x17") = SYS_PUSH_STACK;
  register U64 a0 asm("x10") = SYS_PUSH_FN_POINTER;
  register U64 a1 asm("x11") = value;

  asm volatile("ecall" : "+r"(a0) : "r"(a1), "r"(a7) : "memory");
}

U32 emu_out_pop_u32() {
  register U64 a7 asm("x17") = SYS_POP_STACK;
  register U32 a0 asm("x10") = SYS_PUSH_FN_U32;

  asm volatile("ecall" : "+r"(a0) : "r"(a7) : "memory");

  return a0;
}

U64 emu_out_pop_u64() {
  register U64 a7 asm("x17") = SYS_POP_STACK;
  register U64 a0 asm("x10") = SYS_PUSH_FN_POINTER;

  asm volatile("ecall" : "+r"(a0) : "r"(a7) : "memory");

  return a0;
}

U8 emu_in_read_line(U8 **buf, U64 *len) {
    const U8 func_name[] = "core::readln";

    emu_out_call_host_fn(func_name, sizeof(func_name)-1);

    U8 *popped_buf = (U8 *)emu_out_pop_u64();
    if (buf == 0) return 1;

    *len = emu_out_pop_u64();
    *buf = popped_buf;

    return 0;
}

void *malloc(size_t size) {
  emu_trap(0xBAD4);
  return 0;
}
void *calloc(size_t num, size_t size) {
  emu_trap(0xBAD5);
  return 0;
}
void *realloc(void *ptr, size_t size) {
  emu_trap(0xBAD6);
  return 0;
}
void free(void *ptr) { emu_trap(0xBAD7); }

