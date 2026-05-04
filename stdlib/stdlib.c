#include "stdlib.h"

static void emu_trap(U16 code) {
  register long a7 asm("x17") = 0xFF;
  register long a0 asm("x10") = (U64)code;

  asm volatile("ecall" : "+r"(a0) : "r"(a7) : "memory");
}

void emu_println(U8 *buf, U64 len) {
  register long a7 asm("x17") = (U64)0xA;
  register long a0 asm("x10") = (U64)buf;
  register long a1 asm("x11") = len;

  asm volatile("ecall" : "+r"(a0) : "r"(a1), "r"(a7) : "memory");
}

/*
U8 *memset(U8 *ptr, int value, size_t num) {
  // emu_trap(0xBAD1);

  for (int i = 0; i < num; ++i) {
    (*(ptr + i)) = (U8)(value);
  }

  return ptr;
}

void *memmove(void *destination, const void *source, size_t num) {
  emu_trap(0xBAD2);
  return destination;
}

void *memcpy(void *destination, const void *source, size_t num) {
  emu_trap(0xBAD3);

  for (int i = 0; i < num; ++i) {
    (*((U8 *)(destination) + i)) = *((U8 *)(source) + i);
  }

  return destination;
}
*/

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

void _start() {
  // TODO: setup stack and interrupt handlers

  emu_println("stdlib loaded\n", 14);
}
