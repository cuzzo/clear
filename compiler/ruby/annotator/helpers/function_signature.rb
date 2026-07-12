# typed: strict
# Structured representation of a function's external interface.
# Replaces the plain Hash that was previously used for function signatures.
#
# Exposes typed query APIs and named mutation seams while storing
# declared/imported contract fields separately from mutable analysis/codegen
# facts.
require "sorbet-runtime"
require_relative "../../ast/param"
require_relative "../../ast/type"
require_relative "../../ast/ast" # ruby-to-clear: no-require
require_relative "intrinsic_arg_spec"
require_relative "intrinsic_emit"
require_relative "intrinsic_contract"

# ruby-to-clear: pub
class FunctionSignature
  extend T::Sig
  LifetimeSource = T.type_alias { T.any(String, Symbol) }
  LifetimeInput = T.type_alias { T.nilable(T.any(LifetimeSource, T::Array[LifetimeSource])) }
  RequiresMap = T.type_alias { T::Hash[String, T::Set[Symbol]] }
  ExternEffects = T.type_alias { T::Hash[Symbol, Symbol] }
  EffectSet = T.type_alias { T::Set[Symbol] }

  class Contract
    extend T::Sig

    sig { returns(T::Array[AST::Param]) }
    attr_accessor :params
    sig { returns(Type) }
    attr_accessor :return_type
    sig { returns(T::Array[LifetimeSource]) }
    attr_accessor :return_lifetime
    sig { returns(T.nilable(Symbol)) }
    attr_reader :visibility
    sig { returns(T::Array[Symbol]) }
    attr_accessor :type_params
    sig { returns(T::Boolean) }
    attr_reader :reentrant
    sig { returns(T::Boolean) }
    attr_reader :extern
    sig { returns(T.nilable(String)) }
    attr_accessor :module_alias
    sig { returns(ExternEffects) }
    attr_accessor :extern_effects
    sig { returns(T::Array[Symbol]) }
    attr_accessor :fn_type_params
    sig { returns(T.nilable(String)) }
    attr_reader :owner_type
    sig { returns(T::Array[Symbol]) }
    attr_accessor :owner_type_params
    sig { returns(T::Boolean) }
    attr_reader :intrinsic

    sig do
      params(
        params: T::Array[AST::Param],
        visibility: T.nilable(Symbol),
        type_params: T::Array[Symbol],
        reentrant: T::Boolean,
        extern: T::Boolean,
        module_alias: T.nilable(String),
        extern_effects: ExternEffects,
        fn_type_params: T::Array[Symbol],
        owner_type: T.nilable(String),
        owner_type_params: T::Array[Symbol],
        intrinsic: T::Boolean
      ).void
    end
    def initialize(params:, visibility: nil, type_params: [], reentrant: false,
                   extern: false, module_alias: nil, extern_effects: {},
                   fn_type_params: [], owner_type: nil, owner_type_params: [],
                   intrinsic: false)
      @params = T.let(params, T::Array[AST::Param])
      @return_type = T.let(Type.new(:Void), Type)
      @return_lifetime = T.let([], T::Array[LifetimeSource])
      @visibility = T.let(visibility, T.nilable(Symbol))
      @type_params = T.let(type_params.dup, T::Array[Symbol])
      @reentrant = T.let(reentrant, T::Boolean)
      @extern = T.let(extern, T::Boolean)
      @module_alias = T.let(module_alias, T.nilable(String))
      @extern_effects = T.let(extern_effects, ExternEffects)
      @fn_type_params = T.let(fn_type_params.dup, T::Array[Symbol])
      @owner_type = T.let(owner_type, T.nilable(String))
      @owner_type_params = T.let(owner_type_params.dup, T::Array[Symbol])
      @intrinsic = T.let(intrinsic, T::Boolean)
    end
  end

  class AnalysisFacts < T::Struct
    extend T::Sig

    prop :needs_rt, T.nilable(T::Boolean), default: nil
    prop :can_fail, T.nilable(T::Boolean), default: nil
    prop :alloc_fault, T.nilable(T::Boolean), default: nil
    prop :error_fallible, T.nilable(T::Boolean), default: nil
    prop :effects, T.nilable(EffectSet), default: nil
    prop :return_strategy, T.nilable(Symbol), default: nil
    prop :stack_tier, T.nilable(Symbol), default: nil
    prop :requires, RequiresMap, factory: -> { {} }
    prop :heap_carry_return, T.nilable(T::Boolean), default: nil
    prop :heap_carry_return_vars, T.nilable(T::Set[String]), default: nil
    prop :arg_validator, T.nilable(Proc), default: nil
    prop :intrinsic_arg_specs, T::Array[IntrinsicArgSpec], factory: -> { [] }
    prop :intrinsic_fixed_arg_list, T::Boolean, default: false
    prop :intrinsic_varargs, T::Boolean, default: false
    prop :arity, T.nilable(Integer), default: nil
    prop :emit, T.nilable(IntrinsicEmit), default: nil
    prop :return_def, T.nilable(BasicObject), default: nil

    sig { returns(AnalysisFacts) }
    def copy
      AnalysisFacts.new(
        needs_rt: needs_rt,
        can_fail: can_fail,
        alloc_fault: alloc_fault,
        error_fallible: error_fallible,
        effects: effects,
        return_strategy: return_strategy,
        stack_tier: stack_tier,
        requires: FunctionSignature.copy_requires_for_import(requires),
        heap_carry_return: heap_carry_return,
        heap_carry_return_vars: heap_carry_return_vars,
        arg_validator: arg_validator,
        intrinsic_arg_specs: intrinsic_arg_specs.dup,
        intrinsic_fixed_arg_list: intrinsic_fixed_arg_list,
        intrinsic_varargs: intrinsic_varargs,
        arity: arity,
        emit: emit,
        return_def: return_def
      )
    end
  end
  private_constant :Contract, :AnalysisFacts

  # Static signature fields (set at creation)
  sig { returns(T.nilable(Symbol)) }
  def visibility = @contract.visibility

  sig { returns(T::Array[Symbol]) }
  def type_params = @contract.type_params

  sig { returns(T::Boolean) }
  def reentrant = @contract.reentrant

  sig { returns(T.nilable(Symbol)) }
  def return_strategy = @facts.return_strategy

  sig { returns(T::Array[LifetimeSource]) }
  def return_lifetime = @contract.return_lifetime

  # Always a list of AST::Param (coerced at the seam). No Hash.
  sig { returns(T::Array[AST::Param]) }
  def params = @contract.params

  # Seam: a function signature's return is ALWAYS a Type (Void for
  # "no value"). Coerced here so callers may pass nil/Symbol during
  # construction or late return-inference assignment without any
  # reader ever needing a Symbol/Type/nil discriminator.
  sig { returns(Type) }
  def return_type = @contract.return_type

  # EXTERN function fields
  sig { returns(T::Boolean) }
  def extern = @contract.extern

  sig { returns(T.nilable(String)) }
  def module_alias = @contract.module_alias

  sig { returns(ExternEffects) }
  def extern_effects = @contract.extern_effects

  sig { returns(T::Array[Symbol]) }
  def fn_type_params = @contract.fn_type_params

  sig { returns(T.nilable(String)) }
  def owner_type = @contract.owner_type

  sig { returns(T::Array[Symbol]) }
  def owner_type_params = @contract.owner_type_params

  sig { returns(T::Boolean) }
  def intrinsic = @contract.intrinsic

  sig { returns(T.nilable(T::Boolean)) }
  def needs_rt = @facts.needs_rt

  sig { returns(T.nilable(T::Boolean)) }
  def can_fail = @facts.can_fail

  sig { returns(T.nilable(T::Boolean)) }
  def alloc_fault = @facts.alloc_fault

  sig { returns(T.nilable(T::Boolean)) }
  def error_fallible = @facts.error_fallible

  sig { returns(T.nilable(EffectSet)) }
  def effects = @facts.effects

  sig { returns(T.nilable(Symbol)) }
  def stack_tier = @facts.stack_tier

  sig { returns(T.nilable(Proc)) }
  def arg_validator = @facts.arg_validator

  sig { returns(T::Array[IntrinsicArgSpec]) }
  def intrinsic_arg_specs = @facts.intrinsic_arg_specs

  sig { returns(T::Boolean) }
  def intrinsic_fixed_arg_list? = @facts.intrinsic_fixed_arg_list

  sig { returns(T::Boolean) }
  def intrinsic_varargs? = @facts.intrinsic_varargs

  sig { returns(String) }
  def intrinsic_args_label
    return "(varargs)" if intrinsic_varargs?

    display_types = intrinsic_arg_specs.map(&:display_type)
    "(#{display_types.join(', ')})"
  end

  sig { returns(T.nilable(Integer)) }
  def arity = @facts.arity

  sig { returns(T.nilable(IntrinsicEmit)) }
  def emit = @facts.emit

  sig { returns(IntrinsicContract) }
  def intrinsic_contract
    emit = @facts.emit
    emit ? IntrinsicContract.from_emit(emit, @contract.params) : IntrinsicContract.empty
  end
  sig { returns(RequiresMap) }
  def requires = @facts.requires

  sig { returns(T.nilable(T::Boolean)) }
  def heap_carry_return = @facts.heap_carry_return

  sig { returns(T.nilable(T::Set[String])) }
  def heap_carry_return_vars = @facts.heap_carry_return_vars

  # Intrinsic signature semantics (set by the registry converter; nil
  # for ordinary user functions). `arg_validator` the custom arg
  # type-checker; `intrinsic_arg_specs` the typed args shape; `emit` the
  # typed codegen/dispatch metadata (IntrinsicEmit).
  # Strongly-typed return (FunctionReturn) lives in
  # function_signature_returns.rb. Core FunctionSignature intentionally keeps
  # the slot raw so Type can import callable signatures without pulling
  # FunctionReturn back through the type/signature cycle.

  # P2: REQUIRES clause as { param_name_string => Set[Symbol] } or nil.
  # Mirrors FunctionDef#requires; needed at signature level so call-site
  # checks survive cross-module flow.

  # Canonical adapter: a function binding's signature is stored as a
  # Type whose @raw is the FunctionSignature (the SymbolEntry#type
  # seam). Some producers still hand back a bare FunctionSignature.
  # Every reader that needs the signature goes through here so no site
  # re-derives the Type/FunctionSignature/nil split.
  sig { params(x: T.nilable(T.any(Type, FunctionSignature, T::Array[FunctionSignature]))).returns(T.nilable(FunctionSignature)) }
  def self.unwrap(x)
    return x if x.is_a?(FunctionSignature)
    if x.is_a?(Type)
      type = x
      function_type = type.function_type
      return nil unless function_type

      source_signature = T.cast(function_type.source_signature, T.nilable(FunctionSignature))
      return source_signature if source_signature
    end

    nil
  end

  # ruby-to-clear: skip
  sig { params(fn: AST::FunctionDef).returns(FunctionSignature) }
  # ruby-to-clear: skip
  def self.from_function_def(fn)
    raw_sig = unwrap(fn.full_type) || fn.full_type

    sig = if raw_sig.is_a?(FunctionSignature)
      raw_sig.dup
    else
      FunctionSignature.new(
        params: fn.params,
        return_type: fn.annotation_return_type,
        return_lifetime: function_def_lifetime_paths(fn),
        visibility: fn.visibility,
        type_params: fn.type_params.map(&:to_sym),
        reentrant: fn.declared_plain_reentrant?
      )
    end

    sync_signature_from_function_def!(sig, fn)
  end

  # ruby-to-clear: skip
  sig { params(fn: AST::FunctionDef).returns(T::Array[LifetimeSource]) }
  # ruby-to-clear: skip
  def self.function_def_lifetime_paths(fn)
    rl = fn.return_lifetime
    return [] if rl.nil?
    return [:wildcard] if rl == :wildcard

    sources = rl.is_a?(Array) ? rl : [rl]
    sources.filter_map do |source|
      if source.respond_to?(:name)
        T.unsafe(source).name.to_s
      elsif source.respond_to?(:field) && source.respond_to?(:target)
        lifetime_source_path(source).join(".")
      elsif source.is_a?(String) || source.is_a?(Symbol)
        source
      end
    end
  end

  # ruby-to-clear: skip
  sig { params(source: BasicObject).returns(T::Array[String]) }
  # ruby-to-clear: skip
  def self.lifetime_source_path(source)
    parts = T.let([], T::Array[String])
    current = T.let(source, T.nilable(BasicObject))
    while current
      if T.unsafe(current).respond_to?(:field) && T.unsafe(current).respond_to?(:target)
        parts.unshift(T.unsafe(current).field.to_s)
        current = T.unsafe(current).target
      elsif T.unsafe(current).respond_to?(:name)
        parts.unshift(T.unsafe(current).name.to_s)
        break
      else
        break
      end
    end
    parts
  end

  sig do
    params(
      return_type: Type,
      allocates: T::Boolean,
      borrows: T.nilable(T.any(Symbol, T::Array[Symbol])),
      can_fail: T.nilable(T::Boolean),
      return_alloc: T.nilable(Symbol),
    ).returns(FunctionSignature)
  end
  def self.intrinsic_signature(return_type: Type.new(:Void), allocates: false, borrows: nil,
                              can_fail: nil, return_alloc: nil)
    FunctionSignature.new(
      params: [],
      return_type: return_type,
      intrinsic: true,
      can_fail: can_fail,
      emit: IntrinsicEmit.new(
        allocates: allocates,
        borrows: borrows,
        return_alloc: return_alloc,
      )
    )
  end

  sig { returns(FunctionSignature) }
  def self.allocating_intrinsic
    intrinsic_signature(allocates: true)
  end

  sig { returns(FunctionSignature) }
  def self.borrowing_intrinsic
    intrinsic_signature(borrows: :all)
  end

  # ruby-to-clear: skip
  sig { params(sig: FunctionSignature, fn: T.any(AST::Node, Object, T.untyped)).returns(FunctionSignature) }
  # ruby-to-clear: skip
  def self.sync_signature_from_function_def!(sig, fn)
    T.cast(sig.send(:sync_from_function_def!, fn), FunctionSignature)
  end

  sig do
    params(
      params: T::Array[AST::Param],
      return_type: T.nilable(Type::TypeInput),
      return_lifetime: LifetimeInput,
      visibility: T.nilable(Symbol),
      type_params: T::Array[Symbol],
      reentrant: T::Boolean,
      extern: T::Boolean,
      module_alias: T.nilable(String),
      extern_effects: T.nilable(ExternEffects),
      fn_type_params: T::Array[Symbol],
      owner_type: T.nilable(String),
      owner_type_params: T::Array[Symbol],
      intrinsic: T::Boolean,
      needs_rt: T.nilable(T::Boolean),
      can_fail: T.nilable(T::Boolean),
      alloc_fault: T.nilable(T::Boolean),
      error_fallible: T.nilable(T::Boolean),
      effects: T.nilable(EffectSet),
      return_strategy: T.nilable(Symbol),
      stack_tier: T.nilable(Symbol),
      requires: T.nilable(RequiresMap),
      heap_carry_return: T.nilable(T::Boolean),
      heap_carry_return_vars: T.nilable(T::Set[String]),
      arg_validator: T.nilable(Proc),
      arg_spec: IntrinsicArgSpec::RawArgSpec,
      arity: T.nilable(Integer),
      emit: T.nilable(IntrinsicEmit),
      return_def: T.nilable(BasicObject)
    ).void
  end
  def initialize(params:, return_type: nil, return_lifetime: nil, visibility: nil,
                 type_params: [], reentrant: false, extern: false,
                 module_alias: nil, extern_effects: nil,
                 fn_type_params: [], owner_type: nil, owner_type_params: [],
                 intrinsic: false, needs_rt: nil, can_fail: nil,
                 alloc_fault: nil, error_fallible: nil, effects: nil,
                 return_strategy: nil, stack_tier: nil, requires: nil,
                 heap_carry_return: nil, heap_carry_return_vars: nil,
                 arg_validator: nil, arg_spec: nil, arity: nil, emit: nil,
                 return_def: nil)
    @contract = T.let(
      Contract.new(
        params: params,
        visibility: visibility,
        type_params: type_params,
        reentrant: reentrant,
        extern: extern,
        module_alias: module_alias,
        extern_effects: extern_effects || {},
        fn_type_params: fn_type_params,
        owner_type: owner_type,
        owner_type_params: owner_type_params,
        intrinsic: intrinsic
      ),
      Contract
    )
    @facts = T.let(
      AnalysisFacts.new(
        needs_rt: needs_rt,
        can_fail: can_fail,
        alloc_fault: alloc_fault,
        error_fallible: error_fallible,
        effects: effects,
        return_strategy: return_strategy,
        stack_tier: stack_tier,
        requires: FunctionSignature.copy_requires_for_import(requires || {}),
        heap_carry_return: heap_carry_return,
        heap_carry_return_vars: heap_carry_return_vars,
        arg_validator: arg_validator,
        intrinsic_arg_specs: IntrinsicArgSpec.list_from_registry(arg_spec),
        intrinsic_fixed_arg_list: IntrinsicArgSpec.fixed_list_from_registry?(arg_spec),
        intrinsic_varargs: IntrinsicArgSpec.varargs_from_registry?(arg_spec),
        arity: arity,
        emit: emit,
        return_def: return_def
      ),
      AnalysisFacts
    )
    @contract.return_type = coerce_return_type(return_type)
    @contract.return_lifetime = normalize_lifetime(return_lifetime)
  end

  sig { params(return_type: T.nilable(Type::TypeInput)).returns(FunctionSignature) }
  def replace_return_type!(return_type)
    @contract.return_type = coerce_return_type(return_type)
    self
  end

  sig { params(return_strategy: T.nilable(Symbol)).returns(FunctionSignature) }
  def replace_return_strategy!(return_strategy)
    @facts.return_strategy = return_strategy
    self
  end

  sig { params(emit: T.nilable(IntrinsicEmit)).returns(FunctionSignature) }
  def replace_intrinsic_emit!(emit)
    if emit
      @facts.emit = emit.dup
    else
      @facts.emit = nil
    end
    self
  end

  sig { returns(FunctionSignature) }
  def mark_runtime_required!
    @facts.needs_rt = true
    self
  end

  sig { returns(FunctionSignature) }
  def mark_faulting_allocation!
    @facts.can_fail = true
    @facts.alloc_fault = true
    self
  end

  sig { returns(T::Boolean) }
  def emits_allocating?
    intrinsic_contract.allocation.allocates
  end

  sig { returns(T::Boolean) }
  def mutates_receiver?
    intrinsic_contract.ownership.mutates_receiver
  end

  sig { returns(T::Boolean) }
  def takes_ownership?
    intrinsic_contract.ownership.takes_any?
  end

  sig { returns(T.nilable(Symbol)) }
  def return_alloc
    intrinsic_contract.allocation.return_alloc
  end

  sig { returns(T::Boolean) }
  def intrinsic_takes_value?
    intrinsic_contract.ownership.takes_value
  end

  sig { returns(T::Set[Integer]) }
  def intrinsic_argument_takes_indices
    intrinsic_contract.ownership.argument_takes_indices
  end

  sig { returns(T.nilable(T.any(String, Symbol))) }
  def intrinsic_pattern
    intrinsic_contract.template.zig
  end

  sig { params(kind: IntrinsicTemplateKind).returns(T.nilable(T.any(String, Symbol))) }
  def intrinsic_template(kind)
    intrinsic_contract.template.pattern_for(kind)
  end

  sig { params(kind: IntrinsicTemplateKind).returns(String) }
  def required_intrinsic_template(kind)
    pattern = intrinsic_template(kind)
    raise "registry template missing :#{FunctionSignature.template_kind_label(kind)}" unless pattern

    pattern.to_s.dup
  end

  sig { params(kind: IntrinsicTemplateKind).returns(String) }
  def self.template_kind_label(kind)
    return "zig" if kind == IntrinsicTemplateKind::Zig
    return "numeric_zig" if kind == IntrinsicTemplateKind::NumericZig
    return "sharded_zig" if kind == IntrinsicTemplateKind::ShardedZig
    return "shard_direct_zig" if kind == IntrinsicTemplateKind::ShardDirectZig

    "unknown"
  end

  sig { params(default_name: Symbol).returns(Symbol) }
  def intrinsic_bc_op_or(default_name)
    intrinsic_contract.template.bc_op_or(default_name)
  end

  sig { returns(T::Boolean) }
  def intrinsic_bc?
    intrinsic_contract.template.bc
  end

  sig { params(kind: IntrinsicAllocationKind).returns(T.nilable(Symbol)) }
  def intrinsic_alloc(kind)
    intrinsic_contract.allocation.placeholder(kind)
  end

  sig { returns(T::Boolean) }
  def intrinsic_suspends?
    intrinsic_contract.behavior.suspends
  end

  sig { returns(T::Boolean) }
  def intrinsic_container_borrow?
    intrinsic_contract.ownership.container_borrow
  end

  sig { returns(T::Boolean) }
  def intrinsic_collection_narrowing?
    intrinsic_contract.behavior.narrows_collection_type?
  end

  sig { returns(T::Boolean) }
  def intrinsic_receiver_collection_narrowing?
    intrinsic_contract.behavior.narrows_receiver_collection
  end

  sig { returns(T.nilable(Symbol)) }
  def intrinsic_reject_when
    intrinsic_contract.behavior.reject_when
  end

  sig { returns(T.nilable(String)) }
  def intrinsic_reject_error
    intrinsic_contract.behavior.reject_error
  end

  sig { returns(T.nilable(Symbol)) }
  def intrinsic_error_kind
    intrinsic_contract.behavior.error_kind
  end

  sig { returns(T.nilable(Symbol)) }
  def intrinsic_error_type
    intrinsic_contract.behavior.error_type
  end

  sig { returns(T::Array[String]) }
  def intrinsic_lifetime
    intrinsic_contract.behavior.lifetime
  end

  sig { params(pattern: IntrinsicEmit::StrOrSym, alloc: T.nilable(Symbol)).returns(FunctionSignature) }
  def with_intrinsic_override(pattern:, alloc: nil)
    copy = dup
    emit_copy = T.let(IntrinsicEmit.new, IntrinsicEmit)
    if copy.emit
      emit_copy = T.must(copy.emit).dup
    end
    if pattern.is_a?(Symbol)
      emit_copy.zig = pattern
    elsif pattern.is_a?(String)
      emit_copy.zig = pattern
    end
    emit_copy.alloc = alloc if alloc
    copy.replace_intrinsic_emit!(emit_copy)
    copy
  end

  sig { returns(T::Boolean) }
  def heap_return_alloc?
    return_alloc == :heap
  end

  sig { returns(T::Boolean) }
  def frame_return_alloc?
    return_alloc == :frame
  end

  sig { returns(FunctionSignature) }
  def dup
    copy = FunctionSignature.new(
      params: @contract.params,
      return_type: @contract.return_type,
      return_lifetime: @contract.return_lifetime,
      visibility: @contract.visibility,
      type_params: @contract.type_params,
      reentrant: @contract.reentrant,
      extern: @contract.extern,
      module_alias: @contract.module_alias,
      extern_effects: @contract.extern_effects,
      fn_type_params: @contract.fn_type_params,
      owner_type: @contract.owner_type,
      owner_type_params: @contract.owner_type_params,
      intrinsic: @contract.intrinsic
    )
    copy.__send__(:replace_analysis_storage!, @facts.copy)
    copy
  end

  sig { params(params: T::Array[AST::Param]).returns(T::Array[AST::Param]) }
  def self.copy_params_for_import(params)
    params.map do |param|
      AST::Param.new(
        name: param.name,
        type: Type.copy_type(param.type),
        default: param.default,
        mutable: param.mutable,
        takes: param.takes,
        comptime: param.comptime,
        name_token: param.name_token,
        required: param.required,
        sync: param.sync,
        symbol: nil
      )
    end
  end

  sig { params(requires: RequiresMap).returns(RequiresMap) }
  def self.copy_requires_for_import(requires)
    copied = T.let({}, RequiresMap)
    requires.each do |name, families|
      copied[name] = families.dup
    end
    copied
  end

  private

  sig { params(val: T.nilable(Type::TypeInput)).returns(Type) }
  def coerce_return_type(val)
    return Type.new(:Void) if val.nil?

    Type.new(val)
  end

  # ruby-to-clear: skip
  sig { params(fn: T.any(AST::Node, Object, T.untyped)).returns(FunctionSignature) }
  # ruby-to-clear: skip
  def sync_from_function_def!(fn)
    @facts.needs_rt = fn.needs_rt if fn.respond_to?(:needs_rt)
    @facts.can_fail = fn.can_fail if fn.respond_to?(:can_fail)
    @facts.alloc_fault = fn.alloc_fault if fn.respond_to?(:alloc_fault)
    @facts.error_fallible = fn.error_fallible if fn.respond_to?(:error_fallible)
    @facts.effects = fn.effects if fn.respond_to?(:effects)
    replace_requires_storage!(fn.requires) if fn.respond_to?(:requires)
    @facts.return_strategy = fn.return_strategy if fn.respond_to?(:return_strategy)
    @contract.return_type = coerce_return_type(fn.return_type) if fn.respond_to?(:return_type) && fn.return_type
    @facts.stack_tier = fn.stack_tier if fn.respond_to?(:stack_tier)
    @facts.heap_carry_return = fn.heap_carry_return if fn.respond_to?(:heap_carry_return)
    @facts.heap_carry_return_vars = fn.heap_carry_return_vars if fn.respond_to?(:heap_carry_return_vars)
    self
  end
  protected :sync_from_function_def!

  sig { params(requires: T.nilable(RequiresMap)).void }
  def replace_requires_storage!(requires)
    copied_requires = FunctionSignature.copy_requires_for_import(requires || {})
    @facts.requires = copied_requires
  end

  sig { params(facts: AnalysisFacts).void }
  def replace_analysis_storage!(facts)
    @facts = facts
  end
  protected :replace_analysis_storage!

  sig { params(val: LifetimeInput).returns(T::Array[LifetimeSource]) }
  def normalize_lifetime(val)
    return [] if val.nil?
    raw = T.let([], T::Array[LifetimeSource])
    if val.is_a?(Array)
      raw = val
    else
      raw = [val]
    end
    out = T.let([], T::Array[LifetimeSource])
    i = T.let(0, Integer)
    while i < raw.length
      item = raw.fetch(i)
      if item.is_a?(Symbol)
        out << item.to_s
      else
        out << item
      end
      i += 1
    end
    out
  end
end

require_relative "function_signature_returns" # ruby-to-clear: no-require
