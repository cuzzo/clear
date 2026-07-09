# typed: strict
require "sorbet-runtime"
require_relative "function_signature"
require_relative "function_return"

class FunctionSignature
  extend T::Sig

  # Strongly-typed return metadata. Non-nil; defaults to Fixed(Void). This is
  # split out so ast/type can import the callable signature contract without
  # pulling FunctionReturn back through the Type -> FunctionSignature cycle.
  sig { returns(FunctionReturn) }
  def return_def
    raw = @facts.return_def
    return raw if raw.is_a?(FunctionReturn)

    FunctionReturn.fixed(Type.new(:Void))
  end

  # True iff the return is a static Fixed Type (not receiver-parametric or
  # host-inferred). Callers that only honor a statically-declared owned return
  # gate on this.
  sig { returns(T::Boolean) }
  def fixed_return?
    return_def.fixed?
  end

  sig { returns(FunctionSignature) }
  def intrinsic_call_validation_signature
    specs = intrinsic_arg_specs
    validation_params = T.let([], T::Array[AST::Param])
    index = T.let(0, Integer)
    while index < specs.length
      arg_spec = specs.fetch(index)
      validation_params << AST::Param.new(
        name: arg_spec.name || "arg#{index}",
        type: arg_spec.type,
        required: true,
        mutable: arg_spec.mutable,
        takes: arg_spec.takes
      )
      index += 1
    end
    FunctionSignature.new(
      params: validation_params,
      return_type: return_type,
      intrinsic: true,
      return_def: return_def,
    )
  end

  sig { params(module_alias: T.nilable(String)).returns(FunctionSignature) }
  def import_copy(module_alias:)
    copy = dup
    copy.replace_import_mutable_state!(module_alias: module_alias)
  end

  sig { params(module_alias: T.nilable(String)).returns(FunctionSignature) }
  def replace_import_mutable_state!(module_alias:)
    @contract.params = self.class.copy_params_for_import(@contract.params)
    @contract.type_params = @contract.type_params.dup
    @contract.module_alias = module_alias
    @contract.extern_effects = @contract.extern_effects.dup
    @contract.fn_type_params = @contract.fn_type_params.dup
    @contract.owner_type_params = @contract.owner_type_params.dup
    @facts.effects = @facts.effects&.dup
    @facts.requires = self.class.copy_requires_for_import(@facts.requires)
    @facts.heap_carry_return_vars = @facts.heap_carry_return_vars&.dup
    @facts.return_def = return_def.copy
    self
  end
  protected :replace_import_mutable_state!
end
