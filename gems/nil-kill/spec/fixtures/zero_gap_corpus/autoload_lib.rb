# typed: false
# frozen_string_literal: true

require "sorbet-runtime"

# Reached via autoload (first const reference triggers the load).
# One-line classic def: has an `end` (wrappable) but an empty interior,
# so like the endless def it can only be proven via the runtime record.
class AutoLib
  extend T::Sig

  sig { params(v: T.untyped).returns(T.untyped) }
  def one_line(v); v.to_s.upcase; end
end
