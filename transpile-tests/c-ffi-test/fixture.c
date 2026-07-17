#include "fixture.h"

#include <stdlib.h>
#include <string.h>

struct clear_fixture_handle {
    char name[32];
    int64_t values[4];
};

int clear_fixture_echo_int(int value) { return value; }
unsigned int clear_fixture_echo_uint(unsigned int value) { return value; }
long clear_fixture_echo_long(long value) { return value; }
unsigned long clear_fixture_echo_ulong(unsigned long value) { return value; }
long long clear_fixture_echo_long_long(long long value) { return value; }
unsigned long long clear_fixture_echo_ulong_long(unsigned long long value) { return value; }
size_t clear_fixture_echo_size(size_t value) { return value; }
ptrdiff_t clear_fixture_echo_ptrdiff(ptrdiff_t value) { return value; }
float clear_fixture_echo_float(float value) { return value; }
double clear_fixture_echo_double(double value) { return value; }
int32_t clear_fixture_echo_i32(int32_t value) { return value; }
uint32_t clear_fixture_echo_u32(uint32_t value) { return value; }
int8_t clear_fixture_echo_i8(int8_t value) { return value; }
uint8_t clear_fixture_echo_u8(uint8_t value) { return value; }
int16_t clear_fixture_echo_i16(int16_t value) { return value; }
uint16_t clear_fixture_echo_u16(uint16_t value) { return value; }
int64_t clear_fixture_echo_i64(int64_t value) { return value; }
uint64_t clear_fixture_echo_u64(uint64_t value) { return value; }
char clear_fixture_echo_char(char value) { return value; }
signed char clear_fixture_echo_schar(signed char value) { return value; }
unsigned char clear_fixture_echo_uchar(unsigned char value) { return value; }
short clear_fixture_echo_short(short value) { return value; }
unsigned short clear_fixture_echo_ushort(unsigned short value) { return value; }
bool clear_fixture_echo_bool(bool value) { return value; }
void clear_fixture_noop(void) {}

clear_fixture_record clear_fixture_make_record(int64_t id, double weight) {
    clear_fixture_record result = { id, weight, { 3, 5, 7, 11 } };
    return result;
}

int64_t clear_fixture_sum_record(clear_fixture_record record) {
    return record.id + record.samples[0] + record.samples[1] +
        record.samples[2] + record.samples[3];
}

int64_t clear_fixture_sum_fixed(const int64_t values[4]) {
    return values[0] + values[1] + values[2] + values[3];
}

int clear_fixture_open(const char *name, clear_fixture_handle **out) {
    if (out == NULL || name == NULL || strcmp(name, "reject") == 0) return 7;
    clear_fixture_handle *handle = calloc(1, sizeof(*handle));
    if (handle == NULL) return 12;
    strncpy(handle->name, name, sizeof(handle->name) - 1);
    handle->values[0] = 2;
    handle->values[1] = 4;
    handle->values[2] = 8;
    handle->values[3] = 16;
    *out = handle;
    return 0;
}

int clear_fixture_close(clear_fixture_handle *handle) {
    free(handle);
    return 0;
}

const char *clear_fixture_name(clear_fixture_handle *handle) {
    return handle == NULL ? NULL : handle->name;
}

const char *clear_fixture_find(clear_fixture_handle *handle, int key) {
    return handle != NULL && key == 42 ? handle->name : NULL;
}

int clear_fixture_string_equal(const char *left, const char *right) {
    return left != NULL && right != NULL && strcmp(left, right) == 0;
}

int clear_fixture_fail(int code, int *detail) {
    if (detail != NULL) *detail = code * 10;
    return code;
}

int clear_fixture_apply(int value, clear_fixture_callback callback) {
    return callback == NULL ? -1 : callback(value);
}

const int64_t *clear_fixture_values(clear_fixture_handle *handle) {
    return handle == NULL ? NULL : handle->values;
}

size_t clear_fixture_value_count(clear_fixture_handle *handle) {
    return handle == NULL ? 0 : 4;
}
