# typed: strict
# Structured representation of a function's external interface.
# Replaces the plain Hash that was previously used for function signatures.
#
# Carries both the static signature (params, return type, visibility) and
# computed metadata (needs_rt, can_fail) that callers
# need for code generation and cleanup planning.
require "sorbet-runtime"
require_relative "intrinsic_emit"
require_relative "function_return"

class FunctionSignature
    extend T::Sig
  LifetimeSource = T.type_alias { T.any(String, Symbol) }
  LifetimeInput = T.type_alias { T.nilable(T.any(LifetimeSource, AST::Node, T::Array[T.any(LifetimeSource, AST::Node)])) }
  RequiresMap = T.type_alias { T::Hash[String, T::Set[Symbol]] }
  ExternEffects = T.type_alias { T::Hash[Symbol, Symbol] }
  EffectSet = T.type_alias { T::Set[Symbol] }

  # Static signature fields (set at creation)
  sig { returns(T.nilable(Symbol)) }
  attr_reader :visibility
  sig { returns(T.nilable(T::Array[Symbol])) }
  attr_reader :type_params
  sig { returns(T::Boolean) }
  attr_reader :reentrant

  sig { returns(T.nilable(Symbol)) }
  attr_accessor :return_strategy

  sig { returns(T::Array[LifetimeSource]) }
  attr_reader :return_lifetime

  sig { params(val: LifetimeInput).void }
  def return_lifetime=(val)
    @return_lifetime = normalize_lifetime(val)
  end

  # Always a list of AST::Param (coerced at the seam). No Hash.
  sig { returns(T::Array[AST::Param]) }
  attr_reader :params

  # Seam: a function signature's return is ALWAYS a Type (Void for
  # "no value"). Coerced here so callers may pass nil/Symbol during
  # construction or late return-inference assignment without any
  # reader ever needing a Symbol/Type/nil discriminator.
  sig { returns(Type) }
  attr_reader :return_type

  sig { params(val: T.nilable(Type::TypeInput)).void }
  def return_type=(val)
    @return_type = val.nil? ? Type.new(:Void) : Type.new(val)
  end

  # EXTERN function fields
  sig { returns(T::Boolean) }
  attr_accessor :extern
  sig { returns(T.nilable(String)) }
  attr_accessor :module_alias
  sig { returns(ExternEffects) }
  attr_accessor :extern_effects

  sig { returns(T.nilable(T::Array[Symbol])) }
  attr_accessor :fn_type_params
  sig { returns(T.nilable(String)) }
  attr_accessor :owner_type
  sig { returns(T.nilable(T::Array[Symbol])) }
  attr_accessor :owner_type_params

  sig { returns(T::Boolean) }
  attr_accessor :intrinsic
  sig { returns(T.nilable(T.any(String, Symbol))) }
  attr_accessor :zig_pattern

  sig { returns(T.nilable(T::Boolean)) }
  attr_accessor :needs_rt
  sig { returns(T.nilable(T::Boolean)) }
  attr_accessor :can_fail
  sig { returns(T.nilable(T::Boolean)) }
  attr_accessor :alloc_fault
  sig { returns(T.nilable(T::Boolean)) }
  attr_accessor :error_fallible
  sig { returns(T.nilable(EffectSet)) }
  attr_accessor :effects
  sig { returns(T.nilable(Symbol)) }
  attr_accessor :stack_tier

  sig { returns(T.nilable(Proc)) }
  attr_accessor :arg_validator
  sig { returns(T.untyped) }
  attr_accessor :arg_spec
  sig { returns(T.nilable(Integer)) }
  attr_accessor :arity
  sig { returns(T.nilable(IntrinsicEmit)) }
  attr_accessor :emit
  sig { returns(FunctionReturn) }
  attr_accessor :return_def

  sig { returns(RequiresMap) }
  attr_reader :requires

  sig { params(val: T.nilable(RequiresMap)).void }
  def requires=(val)
    @requires = val || {}
  end

  sig { returns(T.nilable(T::Boolean)) }
  attr_accessor :heap_carry_return
  sig { returns(T.nilable(T::Set[String])) }
  attr_accessor :heap_carry_return_vars

  # Intrinsic signature semantics (set by the registry converter; nil
  # for ordinary user functions). `arg_validator` the custom arg
  # type-checker; `arg_spec` the raw args shape; `emit` the typed
  # codegen/dispatch metadata (IntrinsicEmit).
  # Strongly-typed return (FunctionReturn). Non-nil; defaults to
  # Fixed(Void). The single return facility -- resolve(receiver,
  # args, host) always yields a concrete Type. Replaced the former
  # untyped return_spec (Symbol|Hash|Proc|nil) / return_resolver Proc.

  # P2: REQUIRES clause as { param_name_string => Set[Symbol] } or nil.
  # Mirrors FunctionDef#requires; needed at signature level so call-site
  # checks survive cross-module flow.

  # Canonical adapter: a function binding's signature is stored as a
  # Type whose @raw is the FunctionSignature (the SymbolEntry#type
  # seam). Some producers still hand back a bare FunctionSignature.
  # Every reader that needs the signature goes through here so no site
  # re-derives the Type/FunctionSignature/nil split.
  sig { params(x: T.untyped).returns(T.nilable(FunctionSignature)) }
  def self.unwrap(x)
    return x if x.is_a?(FunctionSignature)
    return x.function_signature if x.is_a?(Type)
    nil
  end

  sig { params(fn: AST::FunctionDef).returns(FunctionSignature) }
  def self.from_function_def(fn)
    raw_sig = unwrap(fn.full_type) || fn.full_type

    sig = if raw_sig.is_a?(FunctionSignature)
      raw_sig.dup
    else
      FunctionSignature.new(
        params: fn.params,
        return_type: fn.annotation_return_type,
        return_lifetime: fn.return_lifetime,
        visibility: fn.visibility,
        type_params: fn.type_params&.map(&:to_sym),
        reentrant: fn.reentrant == :reentrant
      )
    end

    sync_from_function_def!(sig, fn)
  end

  sig do
    params(
      return_type: Type,
      allocates: T::Boolean,
      borrows: T.nilable(T.any(Symbol, T::Array[T.untyped])),
      can_fail: T.nilable(T::Boolean),
      return_alloc: T.nilable(Symbol),
    ).returns(FunctionSignature)
  end
  def self.intrinsic_contract(return_type: Type.new(:Void), allocates: false, borrows: nil,
                              can_fail: nil, return_alloc: nil)
    sig = FunctionSignature.new(params: [], return_type: return_type, intrinsic: true)
    sig.can_fail = can_fail
    sig.emit = IntrinsicEmit.new(
      allocates: allocates,
      borrows: borrows,
      return_alloc: return_alloc,
    )
    sig
  end

  sig { returns(FunctionSignature) }
  def self.allocating_intrinsic
    intrinsic_contract(allocates: true)
  end

  sig { returns(FunctionSignature) }
  def self.borrowing_intrinsic
    intrinsic_contract(borrows: :all)
  end

  sig { returns(FunctionSignature) }
  def self.empty_borrow_intrinsic
    intrinsic_contract(borrows: [])
  end

  sig { params(sig: FunctionSignature, fn: T.untyped).returns(FunctionSignature) }
  def self.sync_from_function_def!(sig, fn)
    sig.needs_rt = fn.needs_rt if fn.respond_to?(:needs_rt)
    sig.can_fail = fn.can_fail if fn.respond_to?(:can_fail)
    sig.alloc_fault = fn.alloc_fault if fn.respond_to?(:alloc_fault)
    sig.error_fallible = fn.error_fallible if fn.respond_to?(:error_fallible)
    sig.effects = fn.effects if fn.respond_to?(:effects)
    sig.requires = fn.requires if fn.respond_to?(:requires)
    sig.return_strategy = fn.return_strategy if fn.respond_to?(:return_strategy)
    sig.return_type = fn.return_type if fn.respond_to?(:return_type) && fn.return_type
    sig.stack_tier = fn.stack_tier if fn.respond_to?(:stack_tier)
    sig.heap_carry_return = fn.heap_carry_return if fn.respond_to?(:heap_carry_return)
    sig.heap_carry_return_vars = fn.heap_carry_return_vars if fn.respond_to?(:heap_carry_return_vars)
    sig
  end

  sig { params(params: T::Array[AST::Param], return_type: T.nilable(Type::TypeInput), return_lifetime: LifetimeInput, visibility: T.nilable(Symbol), type_params: T.nilable(T::Array[Symbol]), reentrant: T::Boolean, extern: T::Boolean, module_alias: T.nilable(String), extern_effects: T.nilable(ExternEffects), fn_type_params: T.nilable(T::Array[Symbol]), owner_type: T.nilable(String), owner_type_params: T.nilable(T::Array[Symbol]), intrinsic: T::Boolean, zig_pattern: T.nilable(T.any(String, Symbol))).void }
  def initialize(params:, return_type: nil, return_lifetime: nil, visibility: nil,
                 type_params: nil, reentrant: false, extern: false,
                 module_alias: nil, extern_effects: nil,
                 fn_type_params: nil, owner_type: nil, owner_type_params: nil,
                 intrinsic: false, zig_pattern: nil)
    @params = params
    @return_type = T.let(Type.new(:Void), Type)
    self.return_type = return_type
    @return_lifetime = T.let([], T::Array[LifetimeSource])
    self.return_lifetime = return_lifetime
    @visibility = T.let(visibility, T.nilable(Symbol))
    @type_params = T.let(type_params, T.nilable(T::Array[Symbol]))
    @reentrant = T.let(reentrant, T::Boolean)
    @extern = T.let(extern, T::Boolean)
    @module_alias = T.let(module_alias, T.nilable(String))
    @extern_effects = T.let(extern_effects || {}, ExternEffects)
    @fn_type_params = T.let(fn_type_params, T.nilable(T::Array[Symbol]))
    @owner_type = T.let(owner_type, T.nilable(String))
    @owner_type_params = T.let(owner_type_params, T.nilable(T::Array[Symbol]))
    @intrinsic = T.let(intrinsic, T::Boolean)
    @zig_pattern = T.let(zig_pattern, T.nilable(T.any(String, Symbol)))
    @needs_rt          = T.let(nil, T.nilable(T::Boolean))
    @can_fail          = T.let(nil, T.nilable(T::Boolean))
    @alloc_fault       = T.let(nil, T.nilable(T::Boolean))
    @error_fallible    = T.let(nil, T.nilable(T::Boolean))
    @effects           = T.let(nil, T.nilable(EffectSet))
    @return_strategy   = T.let(nil, T.nilable(Symbol))
    @stack_tier        = T.let(nil, T.nilable(Symbol))
    @requires          = T.let({}, RequiresMap)
    @heap_carry_return = T.let(nil, T.nilable(T::Boolean))
    @heap_carry_return_vars = T.let(nil, T.nilable(T::Set[String]))
    @arg_validator     = T.let(nil, T.nilable(Proc))
    @arg_spec          = T.let(nil, T.untyped)
    @arity             = T.let(nil, T.nilable(Integer))
    @emit              = T.let(nil, T.nilable(IntrinsicEmit))
    @return_def        = T.let(FunctionReturn.fixed(Type.new(:Void)),
                               FunctionReturn)
  end

  # True iff the return is a static Fixed Type (not receiver-parametric
  # or host-inferred). Callers that only honor a statically-declared
  # owned return (e.g. the MIR HPT_LEAK check) gate on this.
  sig { returns(T::Boolean) }
  def fixed_return? = @return_def.fixed?

  sig { returns(T::Boolean) }
  def emits_allocating?
    @emit&.allocates == true
  end

  sig { returns(T::Boolean) }
  def mutates_receiver?
    @emit&.mutates_receiver == true
  end

  sig { returns(T::Boolean) }
  def takes_ownership?
    emit = @emit
    return false unless emit

    takes_args = emit.takes_args
    emit.takes_value == true || (takes_args ? !takes_args.empty? : false)
  end

  sig { returns(T.nilable(Symbol)) }
  def return_alloc
    @emit&.return_alloc
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
    FunctionSignature.new(
      params: @params, return_type: @return_type, return_lifetime: @return_lifetime,
      visibility: @visibility, type_params: @type_params, reentrant: @reentrant,
      extern: @extern, module_alias: @module_alias, extern_effects: @extern_effects,
      fn_type_params: @fn_type_params, owner_type: @owner_type,
      owner_type_params: @owner_type_params, intrinsic: @intrinsic,
      zig_pattern: @zig_pattern
    ).tap do |s|
      s.needs_rt = @needs_rt
      s.can_fail = @can_fail
      s.alloc_fault = @alloc_fault
      s.error_fallible = @error_fallible
      s.effects = @effects
      s.return_strategy = @return_strategy
      s.stack_tier = @stack_tier
      s.requires = @requires
      s.heap_carry_return = @heap_carry_return
      s.heap_carry_return_vars = @heap_carry_return_vars
      s.arg_validator = @arg_validator
      s.arg_spec = @arg_spec
      s.arity = @arity
      s.emit = @emit
      s.return_def = @return_def
    end
  end

  private

  sig { params(val: LifetimeInput).returns(T::Array[LifetimeSource]) }
  def normalize_lifetime(val)
    return [] if val.nil?
    raw = val.is_a?(Array) ? val : [val]
    raw.map do |item|
      if item.respond_to?(:name)
        item.public_send(:name).to_s
      else
        item.is_a?(Symbol) ? item : item.to_s
      end
    end
  end
end
