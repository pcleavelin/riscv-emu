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

typedef struct {
  U8 *data;
  U32 len;
} String8;

void emu_syscall();
void emu_shutdown(void);
void emu_println(const U8 *buf, U64 len);
void emu_out_call_host_fn(const U8 *buf, U64 len);

void emu_out_push_u32(U32 value);
void emu_out_push_u64(U64 value);

U32 emu_out_pop_u32();
U64 emu_out_pop_u64();

U8 emu_in_read_line(U8 **buf, U64 *len);

U8 *memset(U8 *ptr, int value, size_t num);
void *memmove(void *destination, const void *source, size_t num);
void *memcpy(void *destination, const void *source, size_t num);
void *malloc(size_t size);
void *calloc(size_t num, size_t size);
void *realloc(void *ptr, size_t size);
void free(void *ptr);

#endif
