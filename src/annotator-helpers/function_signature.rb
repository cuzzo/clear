# typed: strict
# Structured representation of a function's external interface.
# Replaces the plain Hash that was previously used for function signatures.
#
# Carries both the static signature (params, return type, visibility) and
# computed metadata (needs_rt, can_fail, return_provenance) that callers
# need for code generation and cleanup planning.
require "sorbet-runtime"
require_relative "intrinsic_emit"
require_relative "function_return"

class FunctionSignature
    extend T::Sig

  # Static signature fields (set at creation)
  attr_reader :visibility, :type_params, :reentrant
  attr_accessor :return_lifetime, :return_strategy

  # Always a list of AST::Param (coerced at the seam). No Hash.
  sig { returns(T::Array[AST::Param]) }
  attr_reader :params

  # Seam: a function signature's return is ALWAYS a Type (Void for
  # "no value"). Coerced here so callers may pass nil/Symbol during
  # construction or late return-inference assignment without any
  # reader ever needing a Symbol/Type/nil discriminator.
  sig { returns(Type) }
  attr_reader :return_type

  sig { params(val: T.untyped).void }
  def return_type=(val)
    @return_type = val.nil? ? Type.new(:Void) : (val.is_a?(Type) ? val : Type.new(val))
  end

  # EXTERN function fields
  attr_accessor :extern, :module_alias, :extern_effects
  attr_accessor :fn_type_params, :owner_type, :owner_type_params

  # Computed metadata (set after annotation passes)
  attr_accessor :needs_rt, :can_fail, :return_provenance, :effects, :stack_tier

  # Intrinsic marker
  attr_accessor :intrinsic, :zig_pattern

  # Intrinsic signature semantics (set by the registry converter; nil
  # for ordinary user functions). `arg_validator` the custom arg
  # type-checker; `arg_spec` the raw args shape; `emit` the typed
  # codegen/dispatch metadata (IntrinsicEmit).
  attr_accessor :arg_validator, :arg_spec, :arity, :emit
  # Strongly-typed return (FunctionReturn). Non-nil; defaults to
  # Fixed(Void). The single return facility -- resolve(receiver,
  # args, host) always yields a concrete Type. Replaced the former
  # untyped return_spec (Symbol|Hash|Proc|nil) / return_resolver Proc.
  attr_accessor :return_def

  # P2: REQUIRES clause as { param_name_string => Set[Symbol] } or nil.
  # Mirrors FunctionDef#requires; needed at signature level so call-site
  # checks survive cross-module flow.
  attr_accessor :requires

  # Canonical adapter: a function binding's signature is stored as a
  # Type whose @raw is the FunctionSignature (the SymbolEntry#type
  # seam). Some producers still hand back a bare FunctionSignature.
  # Every reader that needs the signature goes through here so no site
  # re-derives the Type/FunctionSignature/nil split.
  sig { params(x: T.untyped).returns(T.nilable(FunctionSignature)) }
  def self.unwrap(x)
    return x if x.is_a?(FunctionSignature)
    return x.raw if x.is_a?(Type) && x.raw.is_a?(FunctionSignature)
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

  sig { params(sig: FunctionSignature, fn: T.untyped).returns(FunctionSignature) }
  def self.sync_from_function_def!(sig, fn)
    sig.needs_rt = fn.needs_rt if fn.respond_to?(:needs_rt)
    sig.can_fail = fn.can_fail if fn.respond_to?(:can_fail)
    sig.return_provenance = fn.return_provenance if fn.respond_to?(:return_provenance)
    sig.effects = fn.effects if fn.respond_to?(:effects)
    sig.requires = fn.requires if fn.respond_to?(:requires)
    sig.return_strategy = fn.return_strategy if fn.respond_to?(:return_strategy)
    sig.stack_tier = fn.stack_tier if fn.respond_to?(:stack_tier)
    sig
  end

  sig { params(params: T::Array[AST::Param], return_type: T.nilable(Type), return_lifetime: T.untyped, visibility: T.nilable(Symbol), type_params: T.nilable(T::Array[Symbol]), reentrant: T::Boolean, extern: T::Boolean, module_alias: T.nilable(String), extern_effects: T.nilable(T::Hash[Symbol, Symbol]), fn_type_params: T.nilable(T::Array[Symbol]), owner_type: T.nilable(String), owner_type_params: T.nilable(T::Array[T.untyped]), intrinsic: T::Boolean, zig_pattern: T.nilable(T.any(String, Symbol))).void }
  def initialize(params:, return_type: nil, return_lifetime: nil, visibility: nil,
                 type_params: nil, reentrant: false, extern: false,
                 module_alias: nil, extern_effects: nil,
                 fn_type_params: nil, owner_type: nil, owner_type_params: nil,
                 intrinsic: false, zig_pattern: nil)
    @params = params
    @return_type = T.let(Type.new(:Void), Type)
    self.return_type = return_type
    @return_lifetime = return_lifetime
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
    @return_provenance = T.let(nil, T.untyped)
    @effects           = T.let(nil, T.untyped)
    @return_strategy   = T.let(nil, T.untyped)
    @stack_tier        = T.let(nil, T.untyped)
    @requires          = T.let(nil, T.untyped)
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
  def fixed_return? = @return_def.kind == FunctionReturn::Kind::Fixed

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
      s.return_provenance = @return_provenance
      s.effects = @effects
      s.return_strategy = @return_strategy
      s.stack_tier = @stack_tier
      s.requires = @requires
      s.arg_validator = @arg_validator
      s.arg_spec = @arg_spec
      s.arity = @arity
      s.emit = @emit
      s.return_def = @return_def
    end
  end
end
