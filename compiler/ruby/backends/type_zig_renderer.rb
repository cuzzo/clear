# typed: strict

require "sorbet-runtime"
require_relative "../ast/type"
require_relative "zig_type"

# Backend-owned entry point for semantic Type -> Zig spelling. Type keeps its
# target-neutral shape/query API; backend loading and recursive-position error
# set policy live behind this adapter.
class TypeZigRenderer
  extend T::Sig

  sig { params(type: Type, is_param: T::Boolean, is_field: T::Boolean, nested: T::Boolean).returns(String) }
  def self.render(type, is_param: false, is_field: false, nested: false)
    if nested && type.error_union?
      payload = type.error_union_payload_with_outer_capabilities
      return "anyerror!#{render(payload, is_param: is_param, is_field: is_field, nested: true)}"
    end

    T.unsafe(type).__send__(:compute_zig_type, is_param: is_param, is_field: is_field)
  end
end
