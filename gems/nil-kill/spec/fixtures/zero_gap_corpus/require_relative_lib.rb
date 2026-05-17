# typed: false
# frozen_string_literal: true

require "sorbet-runtime"

# Reached via require_relative. Endless def: NO `end` to anchor a
# suffix wrapper AND no interior body line, so collect_ran? can never
# prove it ran from line coverage -- it MUST surface via a
# source-wrapped runtime record or it would wrongly look unseen.
class RelReq
  extend T::Sig

  sig { params(v: T.untyped).returns(T.untyped) }
  def calc(v) = v.to_s
end
