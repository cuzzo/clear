# typed: strict
# Strongly-typed emission/dispatch metadata for an intrinsic.
#
# The std_lib registries (STD_LIB / POOL_METHODS / SET_METHODS /
# MAP_METHODS / INDEX_OPS / BUILTIN_OPS) stay defined as Hash literals
# (the readable authoring DSL). A startup converter (see EPIC) turns
# each entry into a FunctionSignature whose intrinsic-only codegen
# metadata lives HERE -- a typed value object, never an untyped Hash.
#
# Recursive: sub-descriptors (`eql:`, `cleanup:`, `pool:`,
# `string_map:` ...) are themselves IntrinsicEmit; registry-pointer
# forms (`{ registry: MAP_METHODS }`) carry the registry name in
# `:registry`.
require "sorbet-runtime"

class IntrinsicEmit < T::Struct
  extend T::Sig

  # --- Zig codegen templates (String template, or Symbol macro
  #     directive like :macro_map in STD_LIB) ---
  StrOrSym = T.type_alias { T.any(String, Symbol) }
  prop :zig,               T.nilable(StrOrSym),              default: nil
  prop :numeric_zig,       T.nilable(StrOrSym),              default: nil
  prop :sharded_zig,       T.nilable(StrOrSym),              default: nil
  prop :shard_direct_zig,  T.nilable(StrOrSym),              default: nil

  # --- FSM emission fragments ---
  # FsmOps DSL op-objects, not strings -- passthrough, no coercion.
  prop :fsm_setup,           T.nilable(T::Array[T.untyped]), default: nil
  prop :fsm_state_decls,     T.nilable(T::Array[T.untyped]), default: nil
  prop :fsm_finish_block,    T.nilable(T::Array[T.untyped]), default: nil
  prop :fsm_state_finalize,  T.nilable(T::Array[T.untyped]), default: nil
  prop :fsm_finish_value,    T.nilable(String),              default: nil

  # --- Dispatch flags ---
  prop :bc,                  T::Boolean,                     default: false
  prop :is_method,           T::Boolean,                     default: false
  prop :suspends,            T::Boolean,                     default: false
  prop :narrows_collection,  T::Boolean,                     default: false
  prop :mutates_receiver,    T::Boolean,                     default: false
  prop :allocates,           T::Boolean,                     default: false
  prop :takes_value,         T::Boolean,                     default: false
  prop :container_borrow,    T::Boolean,                     default: false

  # --- Symbol-valued dispatch / allocation ---
  prop :tag,             T.nilable(Symbol),                  default: nil
  prop :builtin,         T.nilable(Symbol),                  default: nil
  prop :alloc,           T.nilable(Symbol),                  default: nil
  prop :return_alloc,    T.nilable(Symbol),                  default: nil
  prop :val_alloc,       T.nilable(Symbol),                  default: nil
  prop :key_alloc,       T.nilable(Symbol),                  default: nil
  prop :shard_alloc,     T.nilable(Symbol),                  default: nil
  prop :sharded_alloc,   T.nilable(Symbol),                  default: nil
  prop :borrows,         T.nilable(T.any(Symbol, T::Array[T.untyped])),
       default: nil
  prop :reject_when,     T.nilable(Symbol),                  default: nil
  prop :bc_op,           T.nilable(Symbol),                  default: nil
  prop :error_kind,     T.nilable(Symbol),                   default: nil
  prop :error_type,     T.nilable(Symbol),                   default: nil
  prop :registry,        T.nilable(Symbol),                  default: nil

  # elem: transient element-type-name hint (merged at lowering, e.g.
  # pool_get_def). fallible_clauses: internal with-block clause
  # structure injected at lowering (not authoring DSL).
  prop :elem,            T.nilable(String),                  default: nil
  prop :fallible_clauses, T.untyped,                         default: nil

  # --- Lifetime sources ---
  prop :lifetime,        T::Array[String],                   default: []
  # --- Strings ---
  prop :reject_error,    T.nilable(String),                  default: nil

  # --- Arg-shape (element typing deferred; union keeps it bounded) ---
  prop :arity,           T.nilable(Integer),                 default: nil
  prop :takes_args,      T.nilable(T::Array[Integer]),       default: nil

  # --- Procs (varying arity by role) ---
  prop :label,           T.nilable(Proc),                    default: nil

  # --- Recursive sub-descriptors ---
  prop :eql,             T.nilable(IntrinsicEmit),           default: nil
  prop :strcmp,          T.nilable(IntrinsicEmit),           default: nil
  prop :cleanup,         T.nilable(IntrinsicEmit),           default: nil
  prop :assert,          T.nilable(IntrinsicEmit),           default: nil
  prop :array,           T.nilable(IntrinsicEmit),           default: nil
  prop :list,            T.nilable(IntrinsicEmit),           default: nil
  prop :pool,            T.nilable(IntrinsicEmit),           default: nil
  prop :set,             T.nilable(IntrinsicEmit),           default: nil
  prop :get,             T.nilable(IntrinsicEmit),           default: nil
  prop :string_raw,      T.nilable(IntrinsicEmit),           default: nil
  prop :string_symbol,   T.nilable(IntrinsicEmit),           default: nil
  prop :string_map,      T.nilable(IntrinsicEmit),           default: nil
  prop :numeric_map,     T.nilable(IntrinsicEmit),           default: nil
  prop :set_collection,  T.nilable(IntrinsicEmit),           default: nil
end
