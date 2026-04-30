require "rspec"
require_relative "../src/annotator"
require_relative "../src/ast/ast"

# Guard test: every AST node class must be reachable from the annotator,
# either via a direct `visit_<NodeName>` method or via the indirect
# dispatch list below.
#
# Why: SemanticAnnotator dispatches AST traversal via
# `method_name = "visit_#{node.class.name.split('::').last}"`. If you add
# a new AST::Locatable Struct class but forget to add a visit_ method
# (and don't route it through one of the indirect-dispatch parents), the
# annotator silently skips it and downstream passes (escape analysis,
# MIR lowering, ...) never see the node. The bug surfaces only when a
# user happens to write code that triggers the new node -- at which
# point you get a NoMethodError or, worse, silently-wrong analysis.
#
# This test makes the "did you wire your new node?" check explicit and
# fails fast at CI time. See docs/agents/walkers-cleanup.md for the
# fuller TRAVERSAL-table proposal we DIDN'T adopt -- this guard is the
# cherry-picked piece.
RSpec.describe "AST walker coverage" do
  # Nodes visited via a parent's visit_ rather than directly. Adding a
  # new entry here is intentional: it documents that the node is a
  # sub-expression of some larger construct whose own visit_ method
  # walks into it.
  INDIRECT_DISPATCH = %w[
    Require StringConcat StructPattern ThrowNode CatchBlock

    SelectOp WhereOp IndexOp OrderByOp LimitOp SkipOp UnnestOp DistinctOp
    EachOp FindOp AnyOp AllOp CountOp SumOp AverageOp MaxOp MinOp
    TakeWhileOp WindowOp BatchWindowOp ReduceOp RecoverOp TapOp
    ShardOp ConcurrentOp JoinOp CollectOp
  ].freeze

  it "every AST::Locatable Struct has a visit_ method or an INDIRECT_DISPATCH entry" do
    locatable_nodes = AST.constants
      .map { |c| [c, AST.const_get(c)] }
      .select { |_, v| v.is_a?(Class) && v < Struct && v.include?(AST::Locatable) }
      .map { |name, _| name.to_s }

    visit_methods =
      (SemanticAnnotator.instance_methods + SemanticAnnotator.private_instance_methods)
        .grep(/^visit_/)
        .map { |m| m.to_s.sub("visit_", "") }

    reachable = visit_methods + INDIRECT_DISPATCH
    missing = locatable_nodes - reachable

    expect(missing).to be_empty, lambda {
      <<~MSG
        New AST::Locatable Struct class(es) without a visit_ method:

          #{missing.map { |n| "AST::#{n}" }.join("\n  ")}

        Either:
          (a) Add `def visit_<Name>(node)` to SemanticAnnotator (or one
              of its included helper modules in src/annotator-helpers/),
              OR
          (b) If the node is a sub-expression visited via a parent's
              visit_ method, add it to INDIRECT_DISPATCH in this spec
              with a comment explaining the dispatch path.

        The annotator dispatches via
          method_name = "visit_#{'#'}{node.class.name.split('::').last}"
        so a node without one is silently skipped.
      MSG
    }
  end

  it "every INDIRECT_DISPATCH entry corresponds to a real AST::Locatable class" do
    locatable_names = AST.constants
      .select { |c| (v = AST.const_get(c); v.is_a?(Class) && v < Struct && v.include?(AST::Locatable)) }
      .map(&:to_s)

    stale = INDIRECT_DISPATCH - locatable_names
    expect(stale).to be_empty,
      "INDIRECT_DISPATCH lists classes that no longer exist: #{stale.inspect}"
  end
end
