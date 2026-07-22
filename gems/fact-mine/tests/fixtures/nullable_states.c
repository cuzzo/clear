#include <stddef.h>

int *direct_null(void) {
  int *value;
  value = NULL;
  return value;
}

int *alias_null(void) {
  int *source;
  int *alias;
  source = NULL;
  alias = source;
  return alias;
}
