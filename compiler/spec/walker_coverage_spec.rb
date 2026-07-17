require "rspec"
require_relative "../ruby/annotator" unless defined?(SemanticAnnotator)
require_relative "../ruby/ast/ast" unless defined?(MIR::ReassignPlan)

# Guard test: every AST node class must be reachable from the annotator,
# either via a direct `visit_<NodeName>` method or via the indirect
# dispatch list below.
#
# Why: TypeAnalysisSession uses an explicit, domain-grouped visitor router. If
# a new AST::Locatable Struct class is not added to that router (or routed
# through one of the indirect-dispatch parents), annotation raises a stable
# internal error. This test catches the missing route earlier and documents
# the intentionally indirect cases.
#
# This test makes the "did you wire your new node?" check explicit and
# fails fast at CI time. See docs/agents/walkers-cleanup.md for the
# fuller TRAVERSAL-table proposal we DIDN'T adopt -- this guard is the
# cherry-picked piece.
RSpec.describe "AST walker coverage" do
  # Nodes visited through a non-visit phase route, or via a parent's visit_
  # rather than directly. Adding a new entry here is intentional: it documents
  # that the node is handled without a dedicated visit_ method.
  # Top-level declarations are consumed by DeclarationIndexer; their member
  # FunctionDefs are inserted into body_statements before body traversal.
  INDIRECT_DISPATCH = %w[
    Program StructDef ExternStructDecl EnumDef UnionDef ProtocolDef
    ImplementationDef ConformanceDef ExternFnDecl

    Require RequireNode StringConcat StructPattern ThrowNode CatchBlock

    SelectOp WhereOp IndexOp OrderByOp LimitOp SkipOp UnnestOp DistinctOp
    EachOp FindOp AnyOp AllOp CountOp SumOp AverageOp MaxOp MinOp
    TakeWhileOp WindowOp BatchWindowOp ReduceOp RecoverOp TapOp
    ShardOp ConcurrentOp JoinOp CollectOp

    LetBinding DestructureTarget
  ].freeze

  it "every AST::Locatable Struct has a visit_ method or an INDIRECT_DISPATCH entry" do
    locatable_nodes = AST.constants
      .map { |c| [c, AST.const_get(c)] }
      .select { |_, v| v.is_a?(Class) && v < Struct && v.include?(AST::Locatable) }
      .map { |name, _| name.to_s }

    visit_methods =
      (Annotator::Phases::TypeAnalysisSession.instance_methods +
        Annotator::Phases::TypeAnalysisSession.private_instance_methods)
        .grep(/^visit_/)
        .map { |m| m.to_s.sub("visit_", "") }

    reachable = visit_methods + INDIRECT_DISPATCH
    missing = locatable_nodes - reachable

    expect(missing).to be_empty, lambda {
      <<~MSG
        New AST::Locatable Struct class(es) without a visit_ method:

          #{missing.map { |n| "AST::#{n}" }.join("\n  ")}

        Either:
          (a) Add `def visit_<Name>(node)` and route it through
              TypeAnalysisSession#dispatch_visit,
              OR
          (b) If the node is a sub-expression visited via a parent's
              visit_ method, add it to INDIRECT_DISPATCH in this spec
              with a comment explaining the dispatch path.

        The explicit dispatch router must account for every direct visitor.
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
