# typed: false
# frozen_string_literal: true

require "sorbet-runtime"

# Methods with `ensure` must remain source-wrapped so collect coverage
# and method records agree.
class EnsurePunt
  extend T::Sig

  sig { params(v: T.untyped).returns(T.untyped) }
  def guarded(v)
    acc = 0
    acc += v.to_i
    acc * 3
  ensure
    acc = acc.to_s if acc
  end
end
