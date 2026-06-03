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

  # Static signature fields (set at creation)
  sig { returns(T.untyped) }
  attr_reader :visibility, :type_params, :reentrant
  sig { returns(T.untyped) }
  attr_accessor :return_strategy

  sig { returns(T::Array[LifetimeSource]) }
  attr_reader :return_lifetime

  sig { params(val: T.untyped).void }
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

  sig { params(val: T.any(Symbol, String, Type, FunctionSignature, NilClass)).void }
  def return_type=(val)
    @return_type = val.nil? ? Type.new(:Void) : (val.is_a?(Type) ? val : Type.new(val))
  end

  # EXTERN function fields
  sig { returns(T.untyped) }
  attr_accessor :extern, :module_alias, :extern_effects
  sig { returns(T.untyped) }
  attr_accessor :fn_type_params, :owner_type, :owner_type_params

  # Computed metadata (set after annotation passes)
  sig { returns(T.untyped) }
  attr_accessor :needs_rt, :can_fail, :alloc_fault, :error_fallible, :effects, :stack_tier

  # Intrinsic marker
  sig { returns(T.untyped) }
  attr_accessor :intrinsic, :zig_pattern

  # Intrinsic signature semantics (set by the registry converter; nil
  # for ordinary user functions). `arg_validator` the custom arg
  # type-checker; `arg_spec` the raw args shape; `emit` the typed
  # codegen/dispatch metadata (IntrinsicEmit).
  sig { returns(T.untyped) }
  attr_accessor :arg_validator, :arg_spec, :arity, :emit
  # Strongly-typed return (FunctionReturn). Non-nil; defaults to
  # Fixed(Void). The single return facility -- resolve(receiver,
  # args, host) always yields a concrete Type. Replaced the former
  # untyped return_spec (Symbol|Hash|Proc|nil) / return_resolver Proc.
  sig { returns(T.untyped) }
  attr_accessor :return_def

  # P2: REQUIRES clause as { param_name_string => Set[Symbol] } or nil.
  # Mirrors FunctionDef#requires; needed at signature level so call-site
  # checks survive cross-module flow.
  sig { returns(T.untyped) }
  attr_accessor :requires

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
        return_type: fn.return_type || Type.new(:Any),
        return_lifetime: fn.return_lifetime,
        visibility: fn.visibility,
        type_params: fn.type_params,
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

  sig { params(params: T::Array[AST::Param], return_type: T.any(Symbol, String, Type, FunctionSignature, NilClass), return_lifetime: T.untyped, visibility: T.nilable(Symbol), type_params: T.nilable(T::Array[Symbol]), reentrant: T::Boolean, extern: T::Boolean, module_alias: T.nilable(String), extern_effects: T.nilable(T::Hash[Symbol, Symbol]), fn_type_params: T.nilable(T::Array[Symbol]), owner_type: T.nilable(String), owner_type_params: T.nilable(T::Array[T.untyped]), intrinsic: T::Boolean, zig_pattern: T.nilable(T.any(String, Symbol))).void }
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
    @visibility = visibility
    @type_params = type_params
    @reentrant = reentrant
    @extern = extern
    @module_alias = module_alias
    @extern_effects = extern_effects
    @fn_type_params = fn_type_params
    @owner_type = owner_type
    @owner_type_params = owner_type_params
    @intrinsic = intrinsic
    @zig_pattern = zig_pattern
    @needs_rt          = T.let(nil, T.untyped)
    @can_fail          = T.let(nil, T.untyped)
    @alloc_fault       = T.let(nil, T.untyped)
    @error_fallible    = T.let(nil, T.untyped)
    @effects           = T.let(nil, T.untyped)
    @return_strategy   = T.let(nil, T.untyped)
    @stack_tier        = T.let(nil, T.untyped)
    @requires          = T.let(nil, T.untyped)
    @heap_carry_return = T.let(nil, T.untyped)
    @heap_carry_return_vars = T.let(nil, T.untyped)
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

  sig { returns(T.untyped) }
  def heap_carry_return = @heap_carry_return

  sig { params(val: T.untyped).void }
  def heap_carry_return=(val)
    @heap_carry_return = val
  end

  sig { returns(T.untyped) }
  def heap_carry_return_vars = @heap_carry_return_vars

  sig { params(val: T.untyped).void }
  def heap_carry_return_vars=(val)
    @heap_carry_return_vars = val
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

  sig { params(val: T.untyped).returns(T::Array[LifetimeSource]) }
  def normalize_lifetime(val)
    return [] if val.nil?
    raw = val.is_a?(Array) ? val : [val]
    raw.map do |item|
      if item.respond_to?(:name)
        item.name.to_s
      else
        T.cast(item.is_a?(Symbol) ? item : item.to_s, LifetimeSource)
      end
    end
  end
end
