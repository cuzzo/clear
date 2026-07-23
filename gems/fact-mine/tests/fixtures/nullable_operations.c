#include <stddef.h>

int dereference_null(void) {
  int *value;
  value = NULL;
  return *value;
}
