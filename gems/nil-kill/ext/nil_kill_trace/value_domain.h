// The value-domain derivation the collector used to delegate back to Ruby.
#ifndef NIL_KILL_VALUE_DOMAIN_H
#define NIL_KILL_VALUE_DOMAIN_H

#include <ruby.h>

void nk_value_domain_init(VALUE mod);

// The observation, with the source-role verdict alongside it: exactly what
// `NilKillRuntimeTrace.native_runtime_value_domain` returned.
VALUE nk_value_domain(VALUE value);

// Shared with the identity rules, which answer the same kinds of question
// about a class and must answer them the same way.
VALUE nk_abs_path(VALUE path);
VALUE nk_root_path(void);
VALUE nk_guard(VALUE (*fn)(VALUE), VALUE arg, VALUE fallback);

#endif
