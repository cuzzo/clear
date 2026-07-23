#include <stdlib.h>

int dereference_allocation(void) {
  int *value;
  value = malloc(sizeof(int));
  return *value;
}

int dereference_reallocation(int *value) {
  value = realloc(value, sizeof(int));
  return *value;
}
