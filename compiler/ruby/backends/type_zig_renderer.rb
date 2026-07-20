# typed: strict

require "sorbet-runtime"
require_relative "../ast/type"
require_relative "zig_type"

# Backend-owned entry point for semantic Type -> Zig spelling. Type keeps its
# target-neutral shape/query API; backend loading and recursive-position error
# set policy live behind this adapter.
class TypeZigRenderer
  extend T::Sig

  sig { params(type: Type, is_param: T::Boolean, is_field: T::Boolean).returns(String) }
  def self.render_async_payload(type, is_param: false, is_field: false)
    unless type.error_union?
      return render(type, is_param: is_param, is_field: is_field, nested: true)
    end

    payload = type.error_union_payload_with_outer_capabilities
    rendered_payload = render(payload, is_param: is_param, is_field: is_field, nested: true)
    "CheatLib.AsyncFallible(#{rendered_payload})"
  end

  sig { params(type: Type, is_param: T::Boolean, is_field: T::Boolean, nested: T::Boolean).returns(String) }
  def self.render(type, is_param: false, is_field: false, nested: false)
    # Zig needs an explicit error set before an optional payload. Its shorthand
    # accepts `!i64`, but not `!?i64`; the latter must be `anyerror!?i64`.
    if type.error_union? && type.success_type.optional?
      payload = type.error_union_payload_with_outer_capabilities
      return "anyerror!#{render(payload, is_param: is_param, is_field: is_field, nested: true)}"
    end
    # Inferred error sets (`!T`) are legal only in function return position.
    # Parameters, fields, and every recursively nested position need an
    # explicit error set.
    if (nested || is_param || is_field) && type.error_union?
      payload = type.error_union_payload_with_outer_capabilities
      return "anyerror!#{render(payload, is_param: is_param, is_field: is_field, nested: true)}"
    end

    type.render_zig_type(is_param: is_param, is_field: is_field)
  end
end
