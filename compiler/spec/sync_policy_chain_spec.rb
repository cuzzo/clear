require "rspec"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../ruby/ast/ast" unless defined?(MIR::ReassignPlan)

# True-Sync-Polymorphism step 6 (#328): the policy chain at lowering
# time. For a WITH that didn't get an inline `ON <Error> ...` handler,
# the annotator falls back to the program-level SYNC POLICY (baked-in
# default if no user policy) and synthesizes a per-WITH clause. The
# lowering then takes the same catch path it would take for a
# user-written inline handler.
#
# This spec pins:
#   1. Synthesis fires when SNAPSHOT MUTABLE @versioned has no inline
#      handler — node.lock_error_clause becomes the policy's
#      MvccConflict handler.
#   2. The same fallback runs for SNAPSHOT MATCH MUTABLE's VERSIONED
#      arm when arm.lock_error_clauses is empty.
#   3. The user's user-written SYNC POLICY (when present) takes
#      precedence over the baked-in default; the synthesized clause
#      reflects the user's choice (e.g. RETRY(N) THEN RAISE).
#   4. An inline `ON MvccConflict ...` overrides the policy entirely.
RSpec.describe "SYNC POLICY chain (#328)" do
  def annotate(src)
    tokens = Lexer.new(src).tokenize
    ast = ClearParser.new(tokens, src).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  def find_with(ast)
    AST.walk_body(ast.statements) do |n|
      return n if n.is_a?(AST::WithBlock)
    end
    nil
  end

  describe "1. synthesis: SNAPSHOT MUTABLE without inline handler" do
    it "stamps the baked-in default's MvccConflict handler when no user policy exists" do
      ast = annotate(<<~CLEAR)
        STRUCT C { v: Int64 }
        FN main() RETURNS Void ->
          c = C{ v: 0 } @versioned;
          WITH SNAPSHOT c AS MUTABLE va { va.v = 5; }
          RETURN;
        END
      CLEAR

      with_node = find_with(ast)
      expect(with_node.lock_error_clause).not_to be_nil
      expect(with_node.lock_error_clause.selectors.first.name).to eq(:MvccConflict)
      expect(with_node.lock_error_clause.action).to eq(AST::ErrorActionKind::Raise)
      # The baked-in default for MvccConflict is `RAISE` (no retry).
      expect(with_node.lock_error_clause.retries).to be_nil
    end
  end

  describe "2. synthesis: SNAPSHOT MATCH MUTABLE VERSIONED arm" do
    it "stamps the policy handler on the empty VERSIONED arm" do
      ast = annotate(<<~CLEAR)
        STRUCT Cfg { port: Int64 }
        FN bumpPort(MUTABLE c: Cfg) RETURNS !Void
          REQUIRES c: VERSIONED | ATOMIC
        ->
          WITH SNAPSHOT c AS MUTABLE x MATCH
            WHEN VERSIONED -> { x.port = x.port + 1; }
            WHEN ATOMIC    -> { x.port = x.port + 1; }
          END
          RETURN;
        END
        FN main() RETURNS Void ->
          MUTABLE cfg = Cfg{ port: 80 } @boxed:atomic;
          bumpPort(&cfg);
          RETURN;
        END
      CLEAR

      fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "bumpPort" }
      with_node = fn.body.find { |s| s.is_a?(AST::WithBlock) }
      versioned_arm = with_node.arms.find { |a| a.family == :VERSIONED }
      atomic_arm    = with_node.arms.find { |a| a.family == :ATOMIC }

      # VERSIONED: synthesized clause from policy.
      expect(versioned_arm.lock_error_clauses).not_to be_empty
      sel = versioned_arm.lock_error_clauses.first.selectors.first
      expect(sel.name).to eq(:MvccConflict)

      # ATOMIC: still empty (rcu retries until success; #330 will
      # bound and add AtomicConflict policy fallback).
      expect(atomic_arm.lock_error_clauses).to be_empty
    end
  end

  describe "3. user-written SYNC POLICY overrides the baked-in default" do
    it "synthesizes the user's RETRY(2) THEN RAISE on MvccConflict" do
      ast = annotate(<<~CLEAR)
        SYNC POLICY START
            ON LockTimeout RAISE
            ON MvccConflict RETRY(2) THEN RAISE
            ON AtomicConflict RAISE
        END

        STRUCT C { v: Int64 }
        FN main() RETURNS Void ->
          c = C{ v: 0 } @versioned;
          WITH SNAPSHOT c AS MUTABLE va { va.v = 1; }
          RETURN;
        END
      CLEAR

      with_node = find_with(ast)
      expect(with_node.lock_error_clause.retries).to eq(2)
      expect(with_node.lock_error_clause.action).to eq(AST::ErrorActionKind::Raise)
    end
  end

  describe "4. inline handler overrides policy entirely" do
    it "keeps the inline RETRY(5) THEN PASS in lock_error_clause" do
      ast = annotate(<<~CLEAR)
        STRUCT C { v: Int64 }
        FN main() RETURNS Void ->
          c = C{ v: 0 } @versioned;
          WITH SNAPSHOT c AS MUTABLE va { va.v = 1; } ON MvccConflict RETRY(5) THEN PASS
          RETURN;
        END
      CLEAR

      with_node = find_with(ast)
      expect(with_node.lock_error_clause.retries).to eq(5)
      expect(with_node.lock_error_clause.action).to eq(AST::ErrorActionKind::Pass)
    end
  end
end
