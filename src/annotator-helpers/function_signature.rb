# typed: true
# Structured representation of a function's external interface.
# Replaces the plain Hash that was previously used for function signatures.
#
# Carries both the static signature (params, return type, visibility) and
# computed metadata (needs_rt, can_fail, return_provenance) that callers
# need for code generation and cleanup planning.
require "sorbet-runtime"

class FunctionSignature
    extend T::Sig

  # Static signature fields (set at creation)
  attr_reader :params, :visibility, :type_params, :reentrant
  attr_accessor :return_type, :return_lifetime, :return_strategy

  # EXTERN function fields
  attr_accessor :extern, :module_alias, :extern_effects
  attr_accessor :fn_type_params, :owner_type, :owner_type_params

  # Computed metadata (set after annotation passes)
  attr_accessor :needs_rt, :can_fail, :return_provenance, :effects, :stack_tier

  # Intrinsic marker
  attr_accessor :intrinsic, :zig_pattern

  # P2: REQUIRES clause as { param_name_string => Set[Symbol] } or nil.
  # Mirrors FunctionDef#requires; needed at signature level so call-site
  # checks survive cross-module flow.
  attr_accessor :requires

  sig { params(fn: T.untyped).returns(FunctionSignature) }
  def self.from_function_def(fn)
    raw_sig = fn.full_type
    raw_sig = raw_sig.raw if raw_sig.is_a?(Type) && raw_sig.raw.is_a?(FunctionSignature)

    sig = if raw_sig.is_a?(FunctionSignature)
      raw_sig.dup
    else
      FunctionSignature.new(
        params: fn.params || [],
        return_type: fn.return_type || :Any,
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

  sig { params(params: T::Array[Hash], return_type: T.untyped, return_lifetime: T.untyped, visibility: T.nilable(Symbol), type_params: T.nilable(Array), reentrant: T::Boolean, extern: T::Boolean, module_alias: T.nilable(String), extern_effects: T.nilable(T::Hash[Symbol, T.untyped]), fn_type_params: T.nilable(T::Array[Symbol]), owner_type: T.nilable(String), owner_type_params: T.nilable(Array), intrinsic: T::Boolean, zig_pattern: T.nilable(String)).void }
  def initialize(params:, return_type:, return_lifetime: nil, visibility: nil,
                 type_params: nil, reentrant: false, extern: false,
                 module_alias: nil, extern_effects: nil,
                 fn_type_params: nil, owner_type: nil, owner_type_params: nil,
                 intrinsic: false, zig_pattern: nil)
    @params = params
    @return_type = return_type
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
      s.return_provenance = @return_provenance
      s.effects = @effects
      s.return_strategy = @return_strategy
      s.stack_tier = @stack_tier
      s.requires = @requires
    end
  end
end
