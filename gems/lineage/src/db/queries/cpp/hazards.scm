(
  (qualified_identifier) @hazard.cpp_tsan_concurrency
  (#match? @hazard.cpp_tsan_concurrency "^(std::)?(thread|jthread|async|atomic|mutex|shared_mutex|recursive_mutex|condition_variable|lock_guard|unique_lock|scoped_lock|call_once)")
)

(
  (template_type) @hazard.cpp_tsan_concurrency
  (#match? @hazard.cpp_tsan_concurrency "^(std::)?(thread|jthread|async|atomic|mutex|shared_mutex|recursive_mutex|condition_variable|lock_guard|unique_lock|scoped_lock|call_once)")
)

(
  (type_identifier) @hazard.cpp_tsan_concurrency
  (#match? @hazard.cpp_tsan_concurrency "^(thread|jthread|async|atomic|mutex|shared_mutex|recursive_mutex|condition_variable|lock_guard|unique_lock|scoped_lock|call_once)$")
)

(
  (call_expression function: (field_expression field: (field_identifier) @method)) @hazard.cpp_tsan_concurrency
  (#match? @method "^(lock|try_lock|unlock)$")
)

(
  (call_expression function: (qualified_identifier) @func) @hazard.cpp_asan_raw_memory_api
  (#match? @func "^(std::memcpy|std::memmove|std::memset|memcpy|memmove|memset|strcpy|strncpy|strcat|strncat|sprintf|snprintf)")
)

(
  (call_expression function: (identifier) @func) @hazard.cpp_asan_raw_memory_api
  (#match? @func "^(memcpy|memmove|memset|strcpy|strncpy|strcat|strncat|sprintf|snprintf)")
)

(
  (template_type) @hazard.cpp_asan_raw_memory_api
  (#match? @hazard.cpp_asan_raw_memory_api "^(std::)?span")
)

(
  (type_identifier) @hazard.cpp_asan_raw_memory_api
  (#match? @hazard.cpp_asan_raw_memory_api "string_view")
)

(field_expression operator: "->") @hazard.cpp_asan_pointer_or_cast
(pointer_expression operator: "*") @hazard.cpp_asan_pointer_or_cast

(
  (call_expression function: (template_function name: (identifier) @cast)) @hazard.cpp_asan_pointer_or_cast
  (#match? @cast "^(reinterpret_cast|const_cast)$")
)

(
  (call_expression function: (qualified_identifier) @func) @hazard.cpp_lsan_lifetime
  (#match? @func "^(std::malloc|std::calloc|std::realloc|std::free|malloc|calloc|realloc|free)")
)

(
  (call_expression function: (identifier) @func) @hazard.cpp_lsan_lifetime
  (#match? @func "^(malloc|calloc|realloc|free)")
)

(new_expression) @hazard.cpp_lsan_lifetime
(delete_expression) @hazard.cpp_lsan_lifetime

(
  (binary_expression operator: _ @op) @hazard.cpp_ubsan_arithmetic
  (#match? @op "^(/|%|<<|>>)$")
)

(cast_expression) @hazard.cpp_ubsan_cast

(
  (call_expression function: (template_function name: (identifier) @cast)) @hazard.cpp_ubsan_cast
  (#match? @cast "^(static_cast|dynamic_cast|reinterpret_cast|const_cast)$")
)
