# typed: strict
# Startup converter: std_lib registry Hash entry -> FunctionSignature
# (+ typed IntrinsicEmit). The Hash literals stay the authoring DSL;
# this builds the typed objects consumers will read. Inert until
# consumers are migrated (EPIC #65, per-registry slices).
require_relative "function_signature_returns"
require_relative "intrinsic_arg_spec"
require_relative "intrinsic_emit"

module IntrinsicRegistry
  extend T::Sig


  LookupResult = T.type_alias { T.nilable(T.any(FunctionSignature, T::Array[FunctionSignature])) }
  RegistryKey = T.type_alias { T.any(String, Symbol) }
  RegistryValue = T.type_alias { T.untyped }
  RawEntry = T.type_alias { T::Hash[Symbol, RegistryValue] }
  RawArgSpecEntry = T.type_alias { T.any(Symbol, String, RawEntry) }
  RawArgSpec = T.type_alias { T.nilable(T.any(RawArgSpecEntry, T::Array[RawArgSpecEntry])) }
  RawRegistryEntry = T.type_alias { T.any(RawEntry, T::Array[RawEntry]) }
  RawRegistry = T.type_alias { T::Hash[RegistryKey, RawRegistryEntry] }
  RegistryMap = T.type_alias { T::Hash[Symbol, RawRegistry] }
  SigsTable = T.type_alias { T::Hash[RegistryKey, LookupResult] }
  SigsCache = T.type_alias { T::Hash[Integer, SigsTable] }
  RawEmitInput = T.type_alias { T.nilable(T.any(RawRegistryEntry, Symbol, String, Numeric, T::Boolean)) }
  ReturnDescriptor = T.type_alias { T.nilable(T.any(Type, Symbol, String, RawEntry)) }
  LifetimeInput = T.type_alias { FunctionSignature::LifetimeInput }

  SIGS_CACHE = T.let({}, SigsCache)
  REGISTRY_CONSTANTS = T.let(
    %i[STD_LIB POOL_METHODS SET_METHODS MAP_METHODS INDEX_OPS BUILTIN_OPS].freeze,
    T::Array[Symbol]
  )
  REGISTRY_VALUES = T.let({}, RegistryMap)
  MAP_METHOD_ALIASES_VALUE = T.let({}, T::Hash[String, String])

  # Keys consumed at the FunctionSignature level (not IntrinsicEmit).
  FS_KEYS = %i[args arity validate return return_type can_fail needs_rt].freeze

  EMIT_BOOL = %i[bc is_method suspends narrows_collection
                 narrows_receiver_collection mutates_receiver allocates
                 takes_value container_borrow].freeze
  EMIT_STRSYM = %i[zig numeric_zig sharded_zig shard_direct_zig].freeze
  EMIT_STR    = %i[reject_error elem].freeze
  EMIT_SYM    = %i[tag builtin alloc return_alloc val_alloc key_alloc
                   shard_alloc sharded_alloc reject_when bc_op
                   error_kind error_type].freeze
  # Passthrough (no coercion): borrows (:all|Array), fallible_clauses
  # (internal), fsm_* (FsmOps op-object arrays/expressions, not strings).
  EMIT_PASS   = %i[borrows fallible_clauses fsm_setup fsm_state_decls
                   fsm_finish_block fsm_state_finalize fsm_finish_value label].freeze
  EMIT_INTARR = %i[takes_args].freeze
  EMIT_NESTED = %i[eql strcmp cleanup assert array list pool set get
                   string_raw string_symbol string_map numeric_map
                   set_collection].freeze

  # registries: { Symbol => the registry Hash } (for {registry: X} ptrs)
  sig { params(h: RawEmitInput, registries: RegistryMap).returns(T.nilable(IntrinsicEmit)) }
  def self.build_emit(h, registries)
    return nil unless h.is_a?(Hash)

    e = IntrinsicEmit.new
    h.each do |k, v|
      next if FS_KEYS.include?(k)
      next if v.nil?
      case k
      when *EMIT_BOOL
        assign_emit_bool(e, k, !!v)
      when *EMIT_STRSYM, *EMIT_PASS
        assign_emit_value(e, k, v)
      when *EMIT_STR
        assign_emit_string(e, k, v.to_s)
      when :lifetime
        e.lifetime = normalize_lifetime(v).map(&:to_s)
      when *EMIT_SYM
        assign_emit_symbol(e, k, v.to_sym)
      when *EMIT_INTARR
        assign_emit_int_array(e, k, coerce_int_array(v))
      when *EMIT_NESTED
        assign_emit_nested(e, k, nested_emit(v, registries))
      else
        Kernel.raise "IntrinsicRegistry: unmapped registry key #{k.inspect}"
      end
    end
    e
  end

  sig { params(e: IntrinsicEmit, key: Symbol, value: T::Boolean).void }
  def self.assign_emit_bool(e, key, value)
    case key
    when :bc then e.bc = value
    when :is_method then e.is_method = value
    when :suspends then e.suspends = value
    when :narrows_collection then e.narrows_collection = value
    when :narrows_receiver_collection then e.narrows_receiver_collection = value
    when :mutates_receiver then e.mutates_receiver = value
    when :allocates then e.allocates = value
    when :takes_value then e.takes_value = value
    when :container_borrow then e.container_borrow = value
    else
      unknown_emit_key!(key)
    end
  end

  sig { params(e: IntrinsicEmit, key: Symbol, value: T.untyped).void }
  def self.assign_emit_value(e, key, value)
    case key
    when :zig then e.zig = value
    when :numeric_zig then e.numeric_zig = value
    when :sharded_zig then e.sharded_zig = value
    when :shard_direct_zig then e.shard_direct_zig = value
    when :borrows then e.borrows = value
    when :fallible_clauses then e.fallible_clauses = value
    when :fsm_setup
      e.fsm_setup = value
      e.fsm_setup_present = true
    when :fsm_state_decls
      e.fsm_state_decls = value
      e.fsm_state_decls_present = true
    when :fsm_finish_block
      e.fsm_finish_block = value
      e.fsm_finish_block_present = true
    when :fsm_state_finalize
      e.fsm_state_finalize = value
      e.fsm_state_finalize_present = true
    when :fsm_finish_value then e.fsm_finish_value = value
    when :label then e.label = value
    else
      unknown_emit_key!(key)
    end
  end

  sig { params(e: IntrinsicEmit, key: Symbol, value: String).void }
  def self.assign_emit_string(e, key, value)
    case key
    when :reject_error then e.reject_error = value
    when :elem then e.elem = value
    else
      unknown_emit_key!(key)
    end
  end

  sig { params(e: IntrinsicEmit, key: Symbol, value: Symbol).void }
  def self.assign_emit_symbol(e, key, value)
    case key
    when :tag then e.tag = value
    when :builtin then e.builtin = value
    when :alloc then e.alloc = value
    when :return_alloc then e.return_alloc = value
    when :val_alloc then e.val_alloc = value
    when :key_alloc then e.key_alloc = value
    when :shard_alloc then e.shard_alloc = value
    when :sharded_alloc then e.sharded_alloc = value
    when :reject_when then e.reject_when = value
    when :bc_op then e.bc_op = value
    when :error_kind then e.error_kind = value
    when :error_type then e.error_type = value
    else
      unknown_emit_key!(key)
    end
  end

  sig { params(e: IntrinsicEmit, key: Symbol, value: T::Array[Integer]).void }
  def self.assign_emit_int_array(e, key, value)
    case key
    when :takes_args then e.takes_args = value
    else
      unknown_emit_key!(key)
    end
  end

  sig { params(e: IntrinsicEmit, key: Symbol, value: T.nilable(IntrinsicEmit)).void }
  def self.assign_emit_nested(e, key, value)
    case key
    when :eql then e.eql = value
    when :strcmp then e.strcmp = value
    when :cleanup then e.cleanup = value
    when :assert then e.assert = value
    when :array then e.array = value
    when :list then e.list = value
    when :pool then e.pool = value
    when :set then e.set = value
    when :get then e.get = value
    when :string_raw then e.string_raw = value
    when :string_symbol then e.string_symbol = value
    when :string_map then e.string_map = value
    when :numeric_map then e.numeric_map = value
    when :set_collection then e.set_collection = value
    else
      unknown_emit_key!(key)
    end
  end

  sig { params(value: T.untyped).returns(T::Array[Integer]) }
  def self.coerce_int_array(value)
    raw_values = value.is_a?(Array) ? value : [value]
    out = T.let([], T::Array[Integer])
    i = T.let(0, Integer)
    while i < raw_values.length
      out << raw_values.fetch(i).to_i
      i += 1
    end
    out
  end

  sig { params(key: Symbol).returns(T.noreturn) }
  def self.unknown_emit_key!(key)
    Kernel.raise "IntrinsicRegistry: unmapped registry key #{key.inspect}"
  end

  # A nested sub-descriptor is either another emit Hash or a
  # {registry: <CONST>} pointer (resolved to that registry's name).
  sig { params(v: RawEmitInput, registries: RegistryMap).returns(T.nilable(IntrinsicEmit)) }
  def self.nested_emit(v, registries)
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
  sig { params(rdef: FunctionReturn).returns(Type) }
  def self.to_return_type(rdef)
    if rdef.fixed?
      fixed = rdef.fixed
      Kernel.raise "IntrinsicRegistry: fixed return descriptor missing Type" unless fixed.is_a?(Type)

      fixed
    else
      Type.new(:Any)
    end
  end

  # Declarative receiver-parametric return directives (replace the old
  # `return_type: ->(recv){...}` Procs). Mapped to FunctionReturn
  # variants whose Type is computed from the receiver at resolve time.
  RETURN_VARIANTS = T.let({
    r_element_of:      :ElementOf,
    r_optional_element: :OptionalOfElement,
    r_id_element:      :IdOfElement,
    r_optional_value:  :OptionalOfValue,
    r_value_list:      :ValueList,
    r_key_list:        :KeyList
  }.freeze, T::Hash[Symbol, Symbol])

  # Registry return descriptor -> FunctionReturn (strongly typed,
  # non-nil). No Proc, no Hash, no bare nil escape: every form maps to
  # Fixed(Type) | a receiver-parametric variant | Infer(host method).
  sig { params(v: T.untyped).returns(FunctionReturn) }
  def self.to_return_def(v)
    return FunctionReturn.fixed(Type.new(:Void)) if v.nil?
    return FunctionReturn.fixed(v) if v.is_a?(Type)
    if v.is_a?(Hash)
      return FunctionReturn.fixed(
        v[:type] ? Type.new(v[:type], sync: v[:sync], ownership: v[:ownership])
                 : Type.new(:Any)
      )
    end
    if v.is_a?(Proc)
      Kernel.raise "IntrinsicRegistry: Proc return descriptor is not allowed; " \
                   "use a declarative directive (r_* variant or infer_* host method)"
    end
    kind = v.is_a?(Symbol) ? RETURN_VARIANTS[v] : nil
    if kind
      return FunctionReturn.variant(kind)
    end

    s = v.to_s
    return FunctionReturn.infer(v.to_sym) if s.start_with?("infer_", "macro_")

    FunctionReturn.fixed(Type.new(v))
  end

  sig { params(_name: RegistryKey, h: RawEntry, registries: RegistryMap).returns(FunctionSignature) }
  def self.convert_entry(_name, h, registries)
    ret  = h.key?(:return_type) ? h[:return_type] : h[:return]
    rdef = to_return_def(ret)
    params = params_from_arg_spec(h[:args], h)
    fs = FunctionSignature.new(
      params: params,
      return_type: to_return_type(rdef),
      return_lifetime: normalize_lifetime(h[:lifetime]),
      intrinsic: true,
      return_def: rdef,
      arg_validator: h[:validate].is_a?(Proc) ? h[:validate] : nil,
      arg_spec: h[:args],
      arity: h[:arity],
      can_fail: h[:can_fail],
      needs_rt: h[:needs_rt],
      emit: build_emit(h, registries)
    )
    fs
  end

  sig { params(value: LifetimeInput).returns(T::Array[FunctionSignature::LifetimeSource]) }
  def self.normalize_lifetime(value)
    return [] if value.nil?
    if value.is_a?(Array)
      return value.filter_map { |item| item.is_a?(String) || item.is_a?(Symbol) ? item : nil }
    end
    return [] unless value.is_a?(String) || value.is_a?(Symbol)

    [value]
  end

  sig { params(spec: RawArgSpec, h: RawEntry).returns(T::Array[AST::Param]) }
  def self.params_from_arg_spec(spec, h)
    arg_specs = IntrinsicArgSpec.list_from_registry(spec)

    takes_args = Kernel.Array(h[:takes_args])
    mutates_receiver = h[:mutates_receiver] == true
    params = T.let([], T::Array[AST::Param])
    i = T.let(0, Integer)
    while i < arg_specs.length
      arg_def = arg_specs.fetch(i)
      takes_index = (h[:is_method] || mutates_receiver) ? i - 1 : i
      takes_by_index = takes_index >= 0 && takes_args.include?(takes_index)
      params << AST::Param.new(
        name: arg_def.name || "arg#{i}",
        type: arg_def.type,
        required: true,
        mutable: arg_def.mutable || (i == 0 && mutates_receiver),
        takes: arg_def.takes || takes_by_index
      )
      i += 1
    end
    params
  end

  # Startup conversion (memoized, built once per registry on first
  # access — the registries are frozen constants). The typed view of
  # a whole registry: name -> FunctionSignature, or
  # Array[FunctionSignature] for overload sets (e.g.
  # STD_LIB["charAt"]). Consumers read THIS, never the raw Hash.
  sig { params(reg: RawRegistry).returns(SigsTable) }
  def self.sigs(reg)
    cache_key = reg.object_id
    cached = SIGS_CACHE[cache_key]
    return cached if cached

    registry_map = registries
    out = T.let({}, SigsTable)
    reg.each do |name, entry|
      out[name] =
        if entry.is_a?(Array)
          entry.map { |e| convert_entry(name, e, registry_map) }
        elsif entry.is_a?(Hash)
          convert_entry(name, entry, registry_map)
        end
    end
    SIGS_CACHE[cache_key] = out
    out
  end

  # Registry map built from loaded std_lib constants so there is no
  # load-order coupling. Used by `fs` so call sites need not thread the map.
  sig { returns(RegistryMap) }
  def self.registries
    out = T.let({}, RegistryMap)
    values = registry_values
    i = T.let(0, Integer)
    while i < REGISTRY_CONSTANTS.length
      constant_name = REGISTRY_CONSTANTS.fetch(i)
      registry = values[constant_name]
      out[constant_name] = registry if registry
      i += 1
    end
    out
  end

  sig { returns(RegistryMap) }
  def self.registry_values
    populate_registry_values if REGISTRY_VALUES.empty?

    REGISTRY_VALUES
  end
  private_class_method :registry_values

  sig { returns(NilClass) }
  def self.populate_registry_values
    REGISTRY_VALUES[:STD_LIB] = STD_LIB
    REGISTRY_VALUES[:POOL_METHODS] = POOL_METHODS
    REGISTRY_VALUES[:SET_METHODS] = SET_METHODS
    REGISTRY_VALUES[:MAP_METHODS] = MAP_METHODS
    REGISTRY_VALUES[:INDEX_OPS] = INDEX_OPS
    REGISTRY_VALUES[:BUILTIN_OPS] = BUILTIN_OPS
    MAP_METHOD_ALIASES.each do |key, value|
      MAP_METHOD_ALIASES_VALUE[key] = value
    end
    nil
  end
  private_class_method :populate_registry_values

  # Idempotent normalizer for the flag-day migration: returns a
  # FunctionSignature for a registry/ad-hoc entry Hash, passes a
  # FunctionSignature through unchanged, and maps nil -> nil. Every
  # `*.stdlib_def = X` / `matched_stdlib_def = X` site routes through
  # this so the carried value is always a FunctionSignature.
  sig { params(x: T.untyped, name: RegistryKey).returns(T.nilable(FunctionSignature)) }
  def self.fs(x, name = "_inline")
    return nil if x.nil?
    return x if x.is_a?(FunctionSignature)

    convert_entry(name, x, registries) if x.is_a?(Hash)
  end

  sig { params(name: T.any(String, Symbol), arity: Integer).returns(T::Boolean) }
  def self.collection_element_evidence_method?(name, arity)
    return false unless arity == 1

    method_name = name.to_s
    registries = [STD_LIB, POOL_METHODS, SET_METHODS]
    i = T.let(0, Integer)
    while i < registries.length
      registry = registries.fetch(i)
      fs = FunctionSignature.unwrap(IntrinsicRegistry.lookup(registry, method_name))
      unless fs&.intrinsic_contract&.behavior&.is_method
        i += 1
        next
      end

      return true if T.must(fs).intrinsic_collection_narrowing?
      i += 1
    end
    false
  end

  sig { params(name: T.any(String, Symbol), arity: Integer).returns(T::Boolean) }
  def self.map_pair_evidence_method?(name, arity)
    return false unless arity == 2

    fs = FunctionSignature.unwrap(IntrinsicRegistry.lookup(MAP_METHODS, name.to_s))
    return false unless fs&.intrinsic_contract&.behavior&.is_method

    T.must(fs).mutates_receiver? && T.must(fs).takes_ownership?
  end

  sig { params(name: T.any(String, Symbol), arity: Integer).returns(T::Boolean) }
  def self.collection_value_store_method?(name, arity)
    method_name = name.to_s
    registries = [STD_LIB, POOL_METHODS, SET_METHODS, MAP_METHODS]
    i = T.let(0, Integer)
    while i < registries.length
      registry = registries.fetch(i)
      fs = FunctionSignature.unwrap(IntrinsicRegistry.lookup(registry, method_name))
      unless fs
        i += 1
        next
      end
      method_arity = fs.arity || [fs.params.length - 1, 0].max
      return true if method_arity == arity && fs.intrinsic_contract.behavior.is_method &&
        fs.mutates_receiver? && fs.takes_ownership?
      i += 1
    end
    false
  end

  sig { params(reg: RawRegistry, name: RegistryKey).returns(T::Array[FunctionSignature]) }
  def self.overloads(reg, name)
    result = IntrinsicRegistry.lookup(reg, name)
    return result if result.is_a?(Array)
    return [result] if result.is_a?(FunctionSignature)

    []
  end

  # Typed lookup into a registry: reg[name] as FunctionSignature
  # (or Array[FS] for overloads, or nil if absent). This method is
  # intentionally named `lookup`, not `sig`, so this typed module does
  # not shadow Sorbet's signature DSL.
  sig { params(reg: RawRegistry, name: RegistryKey).returns(LookupResult) }
  def self.lookup(reg, name)
    result = sigs(reg)[name]
    return result if result

    if map_methods_registry?(reg)
      alias_name = MAP_METHOD_ALIASES_VALUE[name.to_s]
      return sigs(reg)[alias_name] if alias_name
    end

    nil
  end
  sig { params(reg: RawRegistry).returns(T::Boolean) }
  def self.map_methods_registry?(reg)
    map_methods = registry_values[:MAP_METHODS]
    return false unless map_methods

    reg.equal?(map_methods)
  end
  private_class_method :map_methods_registry?

  private_class_method :build_emit
  private_class_method :convert_entry
  private_class_method :nested_emit
  private_class_method :normalize_lifetime
  private_class_method :params_from_arg_spec
  private_class_method :registries

end
