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

;; Keep literal operands: x / 0, x % 0, and an oversized literal shift are
;; sanitizer-relevant UB. The operand type determines whether a shift count
;; is oversized, so the query intentionally keeps both literal and dynamic
;; right operands for UBSan to validate.
(
  (binary_expression operator: _ @op right: (_) @rhs) @hazard.c_ubsan_arithmetic
  (#match? @op "^(/|%|<<|>>)$")
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
