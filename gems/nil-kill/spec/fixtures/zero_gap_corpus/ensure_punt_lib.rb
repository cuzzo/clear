# typed: false
# frozen_string_literal: true

require "sorbet-runtime"

# `ensure` -> the inline wrapper cannot express it, so the method is
# punted to the targeted-TracePoint fallback. It must STILL produce a
# record (the fallback fires in-process) -- a multi-line interior so
# collect_ran? would also see it run.
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
