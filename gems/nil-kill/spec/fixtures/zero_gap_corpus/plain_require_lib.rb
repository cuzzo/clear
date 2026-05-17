# typed: false
# frozen_string_literal: true

require "sorbet-runtime"

# Reached via a bare `require "plain_require_lib"` ($LOAD_PATH).
class PlainReq
  extend T::Sig

  sig { params(x: T.untyped).returns(T.untyped) }
  def transform(x)
    doubled = x * 2
    doubled + 1
  end
end
