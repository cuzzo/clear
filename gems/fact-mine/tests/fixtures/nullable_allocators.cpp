#include <cstdlib>

int dereference_allocation() {
  int *value;
  value = static_cast<int *>(malloc(sizeof(int)));
  return *value;
}

int dereference_reallocation(int *value) {
  value = static_cast<int *>(realloc(value, sizeof(int)));
  return *value;
}
