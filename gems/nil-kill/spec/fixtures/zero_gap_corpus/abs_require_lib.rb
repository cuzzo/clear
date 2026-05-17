# typed: false
# frozen_string_literal: true

require "sorbet-runtime"

# Reached via an ABSOLUTE-path require. This is the exact
# collect_bg_blocks shape: a recursive method invoked from inside a
# host `.each do..end` block, with each_pair recursion. Under the old
# parallel-tree redirect this load path bypassed the wrapper -> the
# residual `collect_ran_untraced`. In-place wrapping must record it.
class AbsReq
  extend T::Sig

  sig { params(node: T.untyped, acc: T.untyped).returns(T.untyped) }
  def walk(node, acc)
    case node
    when Array then node.each { |n| walk(n, acc) }
    when Hash  then node.each_pair { |_, v| walk(v, acc) }
    else acc << node
    end
    acc
  end

  sig { params(tree: T.untyped).returns(T.untyped) }
  def run(tree)
    out = []
    [tree].each { |t| walk(t, out) }
    out
  end
end
