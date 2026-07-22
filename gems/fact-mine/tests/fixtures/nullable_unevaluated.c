#include <stddef.h>

size_t c_sizeof_is_not_a_dereference(void) {
  int *value = 0;
  return sizeof(*value) + _Alignof(*value);
}

int c_evaluated_dereference_is_reported(void) {
  int *value = 0;
  return *value;
}
