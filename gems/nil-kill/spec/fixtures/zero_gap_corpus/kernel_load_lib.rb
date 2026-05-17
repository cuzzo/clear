# typed: false
# frozen_string_literal: true

require "sorbet-runtime"

# Reached via Kernel#load. `opts` is a real positional T.untyped slot
# (a sampled NoEvidence candidate -> must get a record). The splat /
# kwsplat / block slots are untraceable-by-design (arg_untraced) and
# must NEVER land in the two forbidden columns.
class KernelLoad
  extend T::Sig

  sig { params(opts: T.untyped, rest: T.untyped, kw: T.untyped, blk: T.untyped).returns(T.untyped) }
  def handle(opts, *rest, **kw, &blk)
    base = opts.fetch(:n, 0)
    base + rest.sum + kw.size + (blk ? blk.call : 0)
  end
end
