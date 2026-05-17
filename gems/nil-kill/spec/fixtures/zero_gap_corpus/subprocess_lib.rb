# typed: false
# frozen_string_literal: true

require "sorbet-runtime"

# Reached ONLY from a spawned `ruby` child process the workload starts
# (a re-exec / Process.spawn boundary). This is precisely the class of
# code the old README disclaimed as "out of scope" -- the actual
# collect_bg_blocks failure. In-place wrapping makes the single copy
# on disk the wrapped one, so the child records it like any other.
class SubProc
  extend T::Sig

  sig { params(payload: T.untyped).returns(T.untyped) }
  def in_child(payload)
    payload.to_s.bytes.sum
  end
end
