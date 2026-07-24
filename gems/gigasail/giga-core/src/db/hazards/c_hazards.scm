(
  (call_expression function: (identifier) @func) @hazard.c_tsan_concurrency
  (#match? @func "^(pthread_create|pthread_mutex_|pthread_rwlock_|pthread_cond_|pthread_spin_|pthread_barrier_|mtx_|cnd_|thrd_create)")
)

(
  (type_identifier) @hazard.c_tsan_concurrency
  (#match? @hazard.c_tsan_concurrency "^(atomic_|__atomic_|__sync_|_Atomic)")
)

(
  (call_expression function: (identifier) @func) @hazard.c_asan_raw_memory_api
  (#match? @func "^(memcpy|memmove|memset|strcpy|strncpy|strcat|strncat|sprintf|snprintf|vsprintf|vsnprintf|gets|scanf|sscanf|fscanf|alloca)$")
)

(
  (call_expression function: (identifier) @func) @hazard.c_lsan_lifetime
  (#match? @func "^(malloc|calloc|realloc|aligned_alloc|posix_memalign|strdup|strndup|free)$")
)

;; Native dynamic loading is a separate boundary from ordinary calls. A
;; runtime trace can show that it was exercised, but cannot validate the
;; library, symbol, ABI, or resulting function pointer.
(
  (call_expression function: (identifier) @func) @hazard.c_dynamic_loading
  (#match? @func "^(dlopen|dlsym|dlclose|dlerror|LoadLibraryA|LoadLibraryW|LoadLibraryExA|LoadLibraryExW|FreeLibrary|GetProcAddress)$")
)

;; Dynamic divisors and shift counts are sanitizer-relevant. Literal zero
;; divisors and literal shift counts >= 32 remain explicit exceptions: safe
;; literals such as 2 and 3 must not become false positives.
(
  (binary_expression operator: _ @op right: (_) @rhs) @hazard.c_ubsan_arithmetic
  (#match? @op "^(/|%|<<|>>)$")
  (#not-match? @rhs "^[0-9]+[uUlL]*$")
)

(
  (binary_expression operator: _ @op right: (number_literal) @rhs) @hazard.c_ubsan_arithmetic
  (#match? @op "^(/|%)$")
  (#match? @rhs "^0([uUlL]*|[xX]0[uUlL]*)$")
)

(
  (binary_expression operator: _ @op right: (number_literal) @rhs) @hazard.c_ubsan_arithmetic
  (#match? @op "^(<<|>>)$")
  (#match? @rhs "^(3[2-9]|[4-9][0-9]|[1-9][0-9]{2,}|0[xX]([2-9A-Fa-f][0-9A-Fa-f]*|1[0-9A-Fa-f]+))[uUlL]*$")
)

;; Only pointer-target casts carry alignment/strict-aliasing UB; value casts
;; like (int)x are not sanitizer-relevant hazards.
(cast_expression
  type: (type_descriptor
    declarator: (abstract_pointer_declarator))) @hazard.c_ubsan_cast

(call_expression
  function: (field_expression)) @hazard.c_callback_invocation

(call_expression
  function: (parenthesized_expression (pointer_expression))) @hazard.c_callback_invocation
