# typed: strict
require "sorbet-runtime"
require_relative "type"
require_relative "../backends/type_zig_renderer"

class AsyncResultShape < T::Struct
  extend T::Sig

  const :kind, Symbol
  const :payload_type, Type

  sig { params(payload_type: Type, shared: T::Boolean).returns(AsyncResultShape) }
  def self.promise(payload_type, shared: false)
    new(kind: shared ? :shared_promise : :promise, payload_type: Type.new(payload_type))
  end

  sig { params(promise_list_type: Type).returns(AsyncResultShape) }
  def self.promise_list_item(promise_list_type)
    payload = promise_list_type.tense_type
    item_expression = T.must(TypeExpressionTree.linear_item_envelope(payload.shape.expression))
    promise(Type.from_child_expression(item_expression))
  end

  sig { returns(T::Boolean) }
  def promise?
    kind == :promise || shared_promise?
  end

  sig { returns(T::Boolean) }
  def shared_promise?
    kind == :shared_promise
  end

  sig { returns(T::Boolean) }
  def boxes_fallible_payload?
    payload_type.error_union?
  end

  sig { returns(String) }
  def payload_zig_type
    TypeZigRenderer.render_async_payload(payload_type)
  end

  sig { returns(String) }
  def handle_zig_type
    wrapper = shared_promise? ? "CheatLib.SharedPromise" : "CheatLib.Promise"
    "#{wrapper}(#{payload_zig_type})"
  end
end
