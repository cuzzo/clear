# Structured representation of a function's external interface.
# Replaces the plain Hash that was previously used for function signatures.
#
# Carries both the static signature (params, return type, visibility) and
# computed metadata (needs_rt, can_fail, return_provenance) that callers
# need for code generation and cleanup planning.
class FunctionSignature
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
    end
  end
end
