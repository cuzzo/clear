// Who a call actually reached: wrapper registry plus owner resolution.
#ifndef NIL_KILL_IDENTITY_H
#define NIL_KILL_IDENTITY_H

#include <ruby.h>

void nk_identity_init(VALUE mod);

// [owner, kind, native, path, line], as the collector records it.
VALUE nk_callee_identity(VALUE defined_class, ID selector, int native);

// Whether this exact (class, selector) is a wrapper the collector installed.
int nk_is_wrapper(VALUE defined_class, ID selector);

void nk_register_wrapper(VALUE defined_class, ID selector, ID owner, ID kind,
                         int native, ID path, int line);

#endif
