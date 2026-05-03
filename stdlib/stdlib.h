#ifndef _PAT_EMU64_H
#define _PAT_EMU64_H

#include <stddef.h>
#include <stdint.h>

typedef uint8_t U8;
typedef uint16_t U16;
typedef uint32_t U32;
typedef uint64_t U64;

typedef int8_t S8;
typedef int16_t S16;
typedef int32_t S32;
typedef int64_t S64;

void emu_syscall();
void emu_println(U8 *buf, U64 len);

U8 *memset(U8 *ptr, int value, size_t num);
void *memmove(void *destination, const void *source, size_t num);
void *memcpy(void *destination, const void *source, size_t num);
void *malloc(size_t size);
void *calloc(size_t num, size_t size);
void *realloc(void *ptr, size_t size);
void free(void *ptr);

#endif
