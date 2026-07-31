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
VALUE nk_type_name(VALUE value);

// The shape of a container as the recorder wants it: [:array, classes, shapes]
// or [:hash, [keys, values], [key_shapes, value_shapes]], or nil when the value
// is not a container. `shapes` are shape keys; ask nk_shape_payload for the
// document each one names.
VALUE nk_container_shape(VALUE value);
VALUE nk_shape_payload(VALUE key);
VALUE nk_nested_shape(VALUE value);

#endif
