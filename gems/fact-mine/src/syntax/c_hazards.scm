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

(field_expression operator: "->") @hazard.c_asan_pointer
(pointer_expression operator: "*") @hazard.c_asan_pointer

(
  (call_expression function: (identifier) @func) @hazard.c_lsan_lifetime
  (#match? @func "^(malloc|calloc|realloc|aligned_alloc|posix_memalign|strdup|strndup|free)$")
)

(
  (binary_expression operator: _ @op) @hazard.c_ubsan_arithmetic
  (#match? @op "^(/|%|<<|>>)$")
)

(cast_expression) @hazard.c_ubsan_cast

(call_expression
  function: (field_expression)) @hazard.c_callback_invocation

(call_expression
  function: (parenthesized_expression (pointer_expression))) @hazard.c_callback_invocation
