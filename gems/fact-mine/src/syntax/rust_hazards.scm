(unsafe_block) @hazard.rust_unsafe_block
((function_item (function_modifiers) @mods) @hazard.rust_unsafe_fn (#match? @mods "unsafe"))
((impl_item) @hazard.rust_unsafe_impl (#match? @hazard.rust_unsafe_impl "^unsafe "))

;; Refined Rust Atomic/Loom queries for precision
(
  (call_expression
    function: (field_expression
      value: _ @recv
      field: (field_identifier) @method)) @hazard.rust_loom_atomic
  (#match? @method "^(load|store|swap)$")
  (#match? @recv "^(?i)(.*(atomic|atom|cell).*|^val$|^cnt$|^seq$|^flag$|^counter$|^state$|_(cnt|counter|state|flag|atomic|atom|ptr))$")
)

(
  (call_expression
    function: (field_expression
      field: (field_identifier) @method)) @hazard.rust_loom_atomic
  (#match? @method "^(compare_exchange|compare_exchange_weak|fetch_add|fetch_sub|fetch_or|fetch_and|fetch_xor|fetch_update)$")
)

(
  (type_identifier) @hazard.rust_loom_atomic
  (#match? @hazard.rust_loom_atomic "^(AtomicBool|AtomicI8|AtomicI16|AtomicI32|AtomicI64|AtomicU8|AtomicU16|AtomicU32|AtomicU64|AtomicUsize|AtomicIsize|AtomicPtr)$")
)

(
  (identifier) @hazard.rust_loom_atomic
  (#match? @hazard.rust_loom_atomic "^(AtomicBool|AtomicI8|AtomicI16|AtomicI32|AtomicI64|AtomicU8|AtomicU16|AtomicU32|AtomicU64|AtomicUsize|AtomicIsize|AtomicPtr)$")
)

(
  (identifier) @hazard.rust_loom_atomic
  (#eq? @hazard.rust_loom_atomic "atomic")
)

(
  (scoped_identifier path: (identifier) @path) @hazard.rust_loom_atomic
  (#eq? @path "Ordering")
)

(
  (call_expression function: (scoped_identifier path: (scoped_identifier name: (identifier) @path) name: (identifier) @func)) @hazard.rust_loom_concurrency
  (#eq? @path "thread")
  (#eq? @func "spawn")
)

(
  (call_expression function: (scoped_identifier path: (identifier) @path name: (identifier) @func)) @hazard.rust_loom_concurrency
  (#eq? @path "thread")
  (#eq? @func "spawn")
)

(
  (generic_type type: (type_identifier) @type) @hazard.rust_loom_concurrency
  (#match? @type "^(Arc|Mutex|RwLock|Condvar)$")
)

(
  (scoped_identifier path: (identifier) @path) @hazard.rust_loom_concurrency
  (#match? @path "^(mpsc|crossbeam)$")
)

(
  (call_expression
    function: (field_expression
      value: _ @recv
      field: (field_identifier) @method)) @hazard.rust_loom_concurrency
  (#match? @method "^(lock|try_lock)$")
  (#match? @recv "^(?i)(.*(lock|mutex|rwlock|condvar|arc|sync).*|^mu$|^m$)$")
)

(
  (call_expression function: (scoped_identifier path: (identifier) @path name: (identifier) @func)) @hazard.rust_unsafe_operation
  (#eq? @path "ptr")
  (#match? @func "^(read|write|copy|copy_nonoverlapping|from_raw|into_raw)$")
)

;; Refined unsafe ptr operation queries for precision
(
  (call_expression
    function: (field_expression
      value: _ @recv
      field: (field_identifier) @method)) @hazard.rust_unsafe_operation
  (#match? @method "^(add|offset|read|write|copy_to|copy_from)$")
  (#match? @recv "^(?i).*(ptr|pointer|raw|addr).*$")
)

(
  (call_expression
    function: (field_expression
      field: (field_identifier) @method)) @hazard.rust_unsafe_operation
  (#match? @method "^(get_unchecked|get_unchecked_mut|unwrap_unchecked|transmute|assume_init)$")
)

(
  (type_identifier) @hazard.rust_unsafe_operation
  (#match? @hazard.rust_unsafe_operation "^(MaybeUninit)$")
)

(
  (macro_invocation macro: (identifier) @macro) @hazard.rust_unsafe_operation
  (#match? @macro "^(addr_of|asm)$")
)

(
  (unary_expression) @hazard.rust_unsafe_operation
  (#match? @hazard.rust_unsafe_operation "^\\*")
)
