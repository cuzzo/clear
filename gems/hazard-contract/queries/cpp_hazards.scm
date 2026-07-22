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
  (call_expression function: (identifier) @func) @hazard.cpp_dynamic_loading
  (#match? @func "^(dlopen|dlsym|dlclose|dlerror|LoadLibraryA|LoadLibraryW|LoadLibraryExA|LoadLibraryExW|FreeLibrary|GetProcAddress)$")
)

(
  (call_expression function: (qualified_identifier) @func) @hazard.cpp_dynamic_loading
  (#match? @func "^(::)?(dlopen|dlsym|dlclose|dlerror|LoadLibraryA|LoadLibraryW|LoadLibraryExA|LoadLibraryExW|FreeLibrary|GetProcAddress)$")
)

;; Dynamic divisors and shift counts are sanitizer-relevant. Literal zero
;; divisors and literal shift counts >= 32 remain explicit exceptions: safe
;; literals such as 2 and 3 must not become false positives.
(
  (binary_expression operator: _ @op right: (_) @rhs) @hazard.cpp_ubsan_arithmetic
  (#match? @op "^(/|%|<<|>>)$")
  (#not-match? @rhs "^[0-9]+[uUlL]*$")
)

(
  (binary_expression operator: _ @op right: (number_literal) @rhs) @hazard.cpp_ubsan_arithmetic
  (#match? @op "^(/|%)$")
  (#match? @rhs "^0([uUlL]*|[xX]0[uUlL]*)$")
)

(
  (binary_expression operator: _ @op right: (number_literal) @rhs) @hazard.cpp_ubsan_arithmetic
  (#match? @op "^(<<|>>)$")
  (#match? @rhs "^(3[2-9]|[4-9][0-9]|[1-9][0-9]{2,}|0[xX]([2-9A-Fa-f][0-9A-Fa-f]*|1[0-9A-Fa-f]+))[uUlL]*$")
)

;; Only pointer-target C-style casts and the type-punning named casts carry
;; UB risk; static_cast and dynamic_cast are checked conversions.
(cast_expression
  type: (type_descriptor
    declarator: (abstract_pointer_declarator))) @hazard.cpp_ubsan_cast

(
  (call_expression function: (template_function name: (identifier) @cast)) @hazard.cpp_ubsan_cast
  (#match? @cast "^(reinterpret_cast|const_cast)$")
)
