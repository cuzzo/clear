# typed: false
# Startup converter: std_lib registry Hash entry -> FunctionSignature
# (+ typed IntrinsicEmit). The Hash literals stay the authoring DSL;
# this builds the typed objects consumers will read. Inert until
# consumers are migrated (EPIC #65, per-registry slices).
require_relative "function_signature"
require_relative "intrinsic_emit"

module IntrinsicRegistry
  module_function

  # Keys consumed at the FunctionSignature level (not IntrinsicEmit).
  FS_KEYS = %i[args arity validate return return_type can_fail needs_rt].freeze

  EMIT_BOOL = %i[bc is_method suspends narrows_collection mutates_receiver
                 allocates takes_value container_borrow].freeze
  EMIT_STRSYM = %i[zig numeric_zig sharded_zig shard_direct_zig].freeze
  EMIT_STR    = %i[lifetime reject_error fsm_finish_value elem].freeze
  EMIT_SYM    = %i[tag builtin alloc return_alloc val_alloc key_alloc
                   shard_alloc sharded_alloc reject_when bc_op
                   error_kind error_type].freeze
  # Passthrough (no coercion): borrows (:all|Array), fallible_clauses
  # (internal), fsm_* (FsmOps op-object arrays, not strings).
  EMIT_PASS   = %i[borrows fallible_clauses fsm_setup fsm_state_decls
                   fsm_finish_block fsm_state_finalize].freeze
  EMIT_SYMARR = %i[value_transforms shard_direct_value_transforms].freeze
  EMIT_INTARR = %i[takes_args].freeze
  EMIT_PROC   = %i[label].freeze
  EMIT_NESTED = %i[eql strcmp cleanup assert array list pool set get
                   string_raw string_symbol string_map numeric_map
                   set_collection].freeze

  # registries: { Symbol => the registry Hash } (for {registry: X} ptrs)
  def build_emit(h, registries)
    return nil unless h.is_a?(Hash)
    e = IntrinsicEmit.new
    h.each do |k, v|
      next if FS_KEYS.include?(k)
      next if v.nil?
      case k
      when *EMIT_BOOL   then e.public_send("#{k}=", !!v)
      when *EMIT_STRSYM then e.public_send("#{k}=", v)
      when *EMIT_STR    then e.public_send("#{k}=", v.to_s)
      when *EMIT_SYM    then e.public_send("#{k}=", v.to_sym)
      when *EMIT_PASS   then e.public_send("#{k}=", v)
      when *EMIT_SYMARR then e.public_send("#{k}=", Array(v).map(&:to_sym))
      when *EMIT_INTARR then e.public_send("#{k}=", Array(v).map(&:to_i))
      when *EMIT_PROC   then e.public_send("#{k}=", v)
      when *EMIT_NESTED
        e.public_send("#{k}=", nested_emit(v, registries))
      else
        raise "IntrinsicRegistry: unmapped registry key #{k.inspect}"
      end
    end
    e
  end

  # A nested sub-descriptor is either another emit Hash or a
  # {registry: <CONST>} pointer (resolved to that registry's name).
  def nested_emit(v, registries)
    return nil unless v.is_a?(Hash)
    if (ptr = v[:registry])
      name = registries.find { |_, r| r.equal?(ptr) }&.first
      return IntrinsicEmit.new(registry: name || :unknown)
    end
    name = registries.find { |_, r| r.equal?(v) }&.first
    return IntrinsicEmit.new(registry: name) if name

    build_emit(v, registries)
  end

  # Symbol/String type-name -> Type. Inference/macro directives
  # (:infer_*, :macro_*) are not type names -> polymorphic placeholder
  # (the real resolution is a later, consumer-side concern).
  def to_return_type(v)
    return Type.new(:Void) if v.nil?
    return Type.new(:Any) if v.is_a?(Proc)
    s = v.to_s
    return Type.new(:Any) if s.start_with?("infer_", "macro_")
    v.is_a?(Type) ? v : Type.new(v)
  end

  def convert_entry(_name, h, registries)
    ret = h.key?(:return_type) ? h[:return_type] : h[:return]
    fs = FunctionSignature.new(
      params: [],
      return_type: to_return_type(ret),
      intrinsic: true
    )
    fs.return_resolver = ret if ret.is_a?(Proc)
    fs.arg_validator   = h[:validate] if h[:validate].is_a?(Proc)
    fs.arg_spec        = h[:args]
    fs.arity           = h[:arity]
    fs.can_fail        = h[:can_fail]
    fs.needs_rt        = h[:needs_rt]
    fs.emit            = build_emit(h, registries)
    fs
  end

  # registries: { Symbol => Hash<String, Hash> }
  def convert_registry(reg, registries)
    reg.each_with_object({}) do |(name, entry), out|
      out[name] = convert_entry(name, entry, registries) if entry.is_a?(Hash)
    end
  end

  # Memoized registry map (built lazily from the std_lib constants so
  # there is no load-order coupling). Used by `fs` so call sites need
  # not thread the map.
  def registries
    @registries ||= %i[STD_LIB POOL_METHODS SET_METHODS MAP_METHODS
                       INDEX_OPS BUILTIN_OPS].each_with_object({}) do |c, h|
      h[c] = Object.const_get(c) if Object.const_defined?(c)
    end
  end

  # Idempotent normalizer for the flag-day migration: returns a
  # FunctionSignature for a registry/ad-hoc entry Hash, passes a
  # FunctionSignature through unchanged, and maps nil -> nil. Every
  # `*.stdlib_def = X` / `matched_stdlib_def = X` site routes through
  # this so the carried value is always a FunctionSignature.
  def fs(x, name = "_inline")
    return nil if x.nil?
    return x if x.is_a?(FunctionSignature)

    convert_entry(name, x, registries) if x.is_a?(Hash)
  end
end
