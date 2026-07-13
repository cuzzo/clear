# typed: strict
require "sorbet-runtime"
require_relative "type"

class AsyncResultShape < T::Struct
  extend T::Sig

  const :kind, Symbol
  const :payload_type, Type

  sig { params(payload_type: Type, shared: T::Boolean).returns(AsyncResultShape) }
  def self.promise(payload_type, shared: false)
    new(kind: shared ? :shared_promise : :promise, payload_type: Type.new(payload_type))
  end

  sig { returns(T::Boolean) }
  def promise?
    kind == :promise || shared_promise?
  end

  sig { returns(T::Boolean) }
  def shared_promise?
    kind == :shared_promise
  end

  sig { returns(String) }
  def handle_zig_type
    wrapper = shared_promise? ? "CheatLib.SharedPromise" : "CheatLib.Promise"
    "#{wrapper}(#{payload_type.zig_type})"
  end
end
