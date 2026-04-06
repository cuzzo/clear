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

  # ── Hash compatibility layer (migration aid) ──────────────────────
  # Allows existing code to use sig[:params], sig.key?(:params), etc.
  # Remove after Phase D when all readers use method access.

  FIELD_MAP = {
    params: :params,
    return: nil,  # special: returns { type:, lifetime: } hash
    visibility: :visibility,
    type_params: :type_params,
    reentrant: :reentrant,
    extern: :extern,
    module_alias: :module_alias,
    extern_effects: :extern_effects,
    fn_type_params: :fn_type_params,
    owner_type: :owner_type,
    owner_type_params: :owner_type_params,
    intrinsic: :intrinsic,
    zig: :zig_pattern,
    return_strategy: :return_strategy,
    needs_rt: :needs_rt,
    can_fail: :can_fail,
    return_provenance: :return_provenance,
    effects: :effects,
    stack_tier: :stack_tier,
  }.freeze

  def [](key)
    if key == :return
      { type: @return_type, lifetime: @return_lifetime }
    elsif FIELD_MAP.key?(key)
      send(FIELD_MAP[key])
    end
  end

  def []=(key, value)
    case key
    when :return
      @return_type = value[:type] if value.is_a?(Hash)
      @return_lifetime = value[:lifetime] if value.is_a?(Hash)
    when :return_strategy then @return_strategy = value
    when :needs_rt then @needs_rt = value
    when :can_fail then @can_fail = value
    when :return_provenance then @return_provenance = value
    when :module_alias then @module_alias = value
    end
  end

  def key?(key)
    FIELD_MAP.key?(key)
  end

  def is_a?(klass)
    return true if klass == Hash  # backward compat: sig.is_a?(Hash) returns true
    super
  end

  def dig(*keys)
    val = self[keys.first]
    return val if keys.length == 1
    val.is_a?(Hash) ? val.dig(*keys[1..]) : nil
  end

  # Used for module imports: sig.merge(module_alias: "math")
  def merge(other_hash)
    dup_sig = self.dup
    other_hash.each do |k, v|
      dup_sig[k] = v if dup_sig.respond_to?(:[]=)
    end
    dup_sig
  end

  # Deep dup for merge
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
