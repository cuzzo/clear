#include <stddef.h>

void invoke_null_callback(void) {
  void (*callback)(void);
  callback = NULL;
  callback();
}

void invoke_uninitialized_callback(void) {
  void (*callback)(void);
  callback();
}
