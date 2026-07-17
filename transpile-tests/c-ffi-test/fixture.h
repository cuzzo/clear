#ifndef CLEAR_C_FFI_FIXTURE_H
#define CLEAR_C_FFI_FIXTURE_H

#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct {
    int64_t id;
    double weight;
    int64_t samples[4];
} clear_fixture_record;

typedef struct clear_fixture_handle clear_fixture_handle;

int clear_fixture_echo_int(int value);
unsigned int clear_fixture_echo_uint(unsigned int value);
long clear_fixture_echo_long(long value);
unsigned long clear_fixture_echo_ulong(unsigned long value);
long long clear_fixture_echo_long_long(long long value);
unsigned long long clear_fixture_echo_ulong_long(unsigned long long value);
size_t clear_fixture_echo_size(size_t value);
ptrdiff_t clear_fixture_echo_ptrdiff(ptrdiff_t value);
float clear_fixture_echo_float(float value);
double clear_fixture_echo_double(double value);
int32_t clear_fixture_echo_i32(int32_t value);
uint32_t clear_fixture_echo_u32(uint32_t value);
int8_t clear_fixture_echo_i8(int8_t value);
uint8_t clear_fixture_echo_u8(uint8_t value);
int16_t clear_fixture_echo_i16(int16_t value);
uint16_t clear_fixture_echo_u16(uint16_t value);
int64_t clear_fixture_echo_i64(int64_t value);
uint64_t clear_fixture_echo_u64(uint64_t value);
char clear_fixture_echo_char(char value);
signed char clear_fixture_echo_schar(signed char value);
unsigned char clear_fixture_echo_uchar(unsigned char value);
short clear_fixture_echo_short(short value);
unsigned short clear_fixture_echo_ushort(unsigned short value);
bool clear_fixture_echo_bool(bool value);
void clear_fixture_noop(void);

clear_fixture_record clear_fixture_make_record(int64_t id, double weight);
int64_t clear_fixture_sum_record(clear_fixture_record record);
int64_t clear_fixture_sum_fixed(const int64_t values[4]);

int clear_fixture_open(const char *name, clear_fixture_handle **out);
int clear_fixture_close(clear_fixture_handle *handle);
const char *clear_fixture_name(clear_fixture_handle *handle);
const char *clear_fixture_find(clear_fixture_handle *handle, int key);
int clear_fixture_string_equal(const char *left, const char *right);
int clear_fixture_fail(int code, int *detail);

typedef int (*clear_fixture_callback)(int value);
int clear_fixture_apply(int value, clear_fixture_callback callback);

const int64_t *clear_fixture_values(clear_fixture_handle *handle);
size_t clear_fixture_value_count(clear_fixture_handle *handle);

#endif
