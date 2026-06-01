# typed: false
# Startup converter: std_lib registry Hash entry -> FunctionSignature
# (+ typed IntrinsicEmit). The Hash literals stay the authoring DSL;
# this builds the typed objects consumers will read. Inert until
# consumers are migrated (EPIC #65, per-registry slices).
require_relative "function_signature"
require_relative "intrinsic_emit"

module IntrinsicRegistry
  extend T::Sig

  module_function

  # Keys consumed at the FunctionSignature level (not IntrinsicEmit).
  FS_KEYS = %i[args arity validate return return_type can_fail needs_rt].freeze

  EMIT_BOOL = %i[bc is_method suspends narrows_collection
                 narrows_receiver_collection mutates_receiver allocates
                 takes_value container_borrow].freeze
  EMIT_STRSYM = %i[zig numeric_zig sharded_zig shard_direct_zig].freeze
  EMIT_STR    = %i[reject_error fsm_finish_value elem].freeze
  EMIT_SYM    = %i[tag builtin alloc return_alloc val_alloc key_alloc
                   shard_alloc sharded_alloc reject_when bc_op
                   error_kind error_type].freeze
  # Passthrough (no coercion): borrows (:all|Array), fallible_clauses
  # (internal), fsm_* (FsmOps op-object arrays, not strings).
  EMIT_PASS   = %i[borrows fallible_clauses fsm_setup fsm_state_decls
                   fsm_finish_block fsm_state_finalize].freeze
  EMIT_INTARR = %i[takes_args].freeze
  EMIT_PROC   = %i[label].freeze
  EMIT_NESTED = %i[eql strcmp cleanup assert array list pool set get
                   string_raw string_symbol string_map numeric_map
                   set_collection].freeze

  # registries: { Symbol => the registry Hash } (for {registry: X} ptrs)
  sig { params(h: T.untyped, registries: T.untyped).returns(T.nilable(IntrinsicEmit)) }
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
      when :lifetime    then e.lifetime = normalize_lifetime(v).map(&:to_s)
      when *EMIT_SYM    then e.public_send("#{k}=", v.to_sym)
      when *EMIT_PASS   then e.public_send("#{k}=", v)
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
  sig { params(v: T.untyped, registries: T.untyped).returns(T.untyped) }
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

  # Best-effort STATIC view of the return, derived from the typed
  # FunctionReturn (single source of truth). Fixed -> its concrete
  # Type; receiver-parametric / host-inferred -> polymorphic
  # placeholder (the real resolution is consumer-side via
  # return_def.resolve, gated by fixed_return?).
  sig { params(rdef: T.untyped).returns(Type) }
  def to_return_type(rdef)
    if rdef.fixed?
      rdef.fixed || Type.new(:Void)
    else
      Type.new(:Any)
    end
  end

  # Declarative receiver-parametric return directives (replace the old
  # `return_type: ->(recv){...}` Procs). Mapped to FunctionReturn
  # variants whose Type is computed from the receiver at resolve time.
  RETURN_VARIANTS = {
    r_element_of:      :ElementOf,
    r_optional_element: :OptionalOfElement,
    r_id_element:      :IdOfElement,
    r_optional_value:  :OptionalOfValue,
    r_value_list:      :ValueList,
    r_key_list:        :KeyList
  }.freeze

  # Registry return descriptor -> FunctionReturn (strongly typed,
  # non-nil). No Proc, no Hash, no bare nil escape: every form maps to
  # Fixed(Type) | a receiver-parametric variant | Infer(host method).
  sig { params(v: T.untyped).returns(T.untyped) }
  def to_return_def(v)
    return FunctionReturn.fixed(Type.new(:Void)) if v.nil?
    return FunctionReturn.fixed(v) if v.is_a?(Type)
    if v.is_a?(Hash)
      return FunctionReturn.fixed(
        v[:type] ? Type.new(v[:type], sync: v[:sync], ownership: v[:ownership])
                 : Type.new(:Any)
      )
    end
    if v.is_a?(Proc)
      raise "IntrinsicRegistry: Proc return descriptor is not allowed; " \
            "use a declarative directive (r_* variant or infer_* host method)"
    end
    if (kind = RETURN_VARIANTS[v])
      return FunctionReturn.variant(kind)
    end

    s = v.to_s
    return FunctionReturn.infer(v.to_sym) if s.start_with?("infer_", "macro_")

    FunctionReturn.fixed(Type.new(v))
  end

  sig { params(_name: T.untyped, h: T.untyped, registries: T.untyped).returns(FunctionSignature) }
  def convert_entry(_name, h, registries)
    ret  = h.key?(:return_type) ? h[:return_type] : h[:return]
    rdef = to_return_def(ret)
    params = params_from_arg_spec(h[:args], h)
    fs = FunctionSignature.new(
      params: params,
      return_type: to_return_type(rdef),
      return_lifetime: normalize_lifetime(h[:lifetime]),
      intrinsic: true
    )
    fs.return_def      = rdef
    fs.arg_validator   = h[:validate] if h[:validate].is_a?(Proc)
    fs.arg_spec        = h[:args]
    fs.arity           = h[:arity]
    fs.can_fail        = h[:can_fail]
    fs.needs_rt        = h[:needs_rt]
    fs.emit            = build_emit(h, registries)
    fs
  end

  sig { params(value: T.untyped).returns(T.untyped) }
  def normalize_lifetime(value)
    return [] if value.nil?
    return value if value.is_a?(Array)

    [value]
  end

  sig { params(spec: T.untyped, h: T.untyped).returns(T.untyped) }
  def params_from_arg_spec(spec, h)
    return [] unless spec.is_a?(Array)
    takes_args = Array(h[:takes_args])
    mutates_receiver = h[:mutates_receiver] == true
    spec.each_with_index.map do |arg_def, i|
      takes_index = (h[:is_method] || mutates_receiver) ? i - 1 : i
      takes_by_index = takes_index >= 0 && takes_args.include?(takes_index)
      if arg_def.is_a?(Hash)
        AST::Param.new(
          name: arg_def[:name] || "arg#{i}",
          type: arg_def[:type],
          required: true,
          mutable: arg_def[:mutable] || (i == 0 && mutates_receiver),
          takes: arg_def[:takes] || takes_by_index
        )
      else
        AST::Param.new(
          name: "arg#{i}",
          type: arg_def,
          required: true,
          mutable: (i == 0 && mutates_receiver),
          takes: takes_by_index
        )
      end
    end
  end

  # registries: { Symbol => Hash<String, Hash> }
  sig { params(reg: T.untyped, registries: T.untyped).void }
  def convert_registry(reg, registries)
    reg.each_with_object({}) do |(name, entry), out|
      out[name] = convert_entry(name, entry, registries) if entry.is_a?(Hash)
    end
  end

  # Startup conversion (memoized, built once per registry on first
  # access — the registries are frozen constants). The typed view of
  # a whole registry: name -> FunctionSignature, or
  # Array[FunctionSignature] for overload sets (e.g.
  # STD_LIB["charAt"]). Consumers read THIS, never the raw Hash.
  sig { params(reg: T.untyped).returns(T.untyped) }
  def sigs(reg)
    (@sigs ||= {})[reg.object_id] ||=
      reg.each_with_object({}) do |(name, entry), out|
        out[name] =
          if entry.is_a?(Array)
            entry.map { |e| convert_entry(name, e, registries) }
          elsif entry.is_a?(Hash)
            convert_entry(name, entry, registries)
          end
      end
  end

  # Memoized registry map (built lazily from the std_lib constants so
  # there is no load-order coupling). Used by `fs` so call sites need
  # not thread the map.
  sig { returns(T.untyped) }
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
  sig { params(x: T.untyped, name: T.untyped).returns(T.untyped) }
  def fs(x, name = "_inline")
    return nil if x.nil?
    return x if x.is_a?(FunctionSignature)

    convert_entry(name, x, registries) if x.is_a?(Hash)
  end

  sig { params(name: T.any(String, Symbol), arity: Integer).returns(T::Boolean) }
  def collection_element_evidence_method?(name, arity)
    return false unless arity == 1

    method_name = name.to_s
    [STD_LIB, POOL_METHODS, SET_METHODS].any? do |registry|
      fs = FunctionSignature.unwrap(IntrinsicRegistry.sig(registry, method_name))
      emit = fs&.emit
      !!(emit&.is_method &&
        (emit.narrows_collection || emit.narrows_receiver_collection))
    end
  end

  sig { params(name: T.any(String, Symbol), arity: Integer).returns(T::Boolean) }
  def map_pair_evidence_method?(name, arity)
    return false unless arity == 2

    fs = FunctionSignature.unwrap(IntrinsicRegistry.sig(MAP_METHODS, name.to_s))
    emit = fs&.emit
    takes_args = emit&.takes_args
    !!(emit&.is_method && emit.mutates_receiver && takes_args && !takes_args.empty?)
  end

  sig { params(name: T.any(String, Symbol), arity: Integer).returns(T::Boolean) }
  def collection_value_store_method?(name, arity)
    method_name = name.to_s
    [STD_LIB, POOL_METHODS, SET_METHODS, MAP_METHODS].any? do |registry|
      fs = FunctionSignature.unwrap(IntrinsicRegistry.sig(registry, method_name))
      next false unless fs
      emit = fs&.emit
      takes_args = emit&.takes_args
      method_arity = fs.arity || [fs.params.length - 1, 0].max
      takes_value = (takes_args && !takes_args.empty?) ||
        fs.params.drop(1).any?(&:takes)
      !!(method_arity == arity && emit&.is_method && emit.mutates_receiver &&
        takes_value)
    end
  end

  # Typed lookup into a registry: reg[name] as FunctionSignature
  # (or Array[FS] for overloads, or nil if absent). This method is
  # intentionally last because its name is `sig`, which shadows the
  # Sorbet DSL inside this module after definition.
  sig { params(reg: T.untyped, name: T.untyped).returns(T.untyped) }
  def sig(reg, name)
    result = sigs(reg)[name]
    return result if result

    if Object.const_defined?(:MAP_METHODS) &&
        Object.const_defined?(:MAP_METHOD_ALIASES) &&
        reg.equal?(Object.const_get(:MAP_METHODS))
      alias_name = Object.const_get(:MAP_METHOD_ALIASES)[name.to_s]
      return sigs(reg)[alias_name] if alias_name
    end

    nil
  end
end
