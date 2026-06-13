require "rspec"
require_relative "../src/backends/transpiler"
require_relative "../src/ast/ast"

# True-Sync-Polymorphism step 9 (#331): integration spec that pins
# the precedence chain, family-rejection cross-pairs, and
# unreachable-handler detection. Other specs in this milestone test
# individual mechanisms in isolation; this one walks combinatorial
# permutations to make sure they compose correctly.
#
# Precedence chain:
#   1. Per-WITH `ON <Error> ...` clause            (highest priority)
#   2. Program `SYNC POLICY START ... END` block   (when present)
#   3. Baked-in system default                     (always present)
#
# Coverage targets:
#   - Precedence: every {inline, user-policy, baked-in} cell with the
#     three resolvable error types (LockTimeout, MvccConflict,
#     AtomicConflict).
#   - Family rejection: REQUIRES X + caller passes Y where Y not in
#     X's admission. Every cross-pair.
#   - Unreachable handler: ON Error on a WITH where Error can't fire.
RSpec.describe "True-Sync-Polymorphism integration (#331)" do
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

  # ── Precedence chain ────────────────────────────────────────

  describe "precedence: inline ON > program SYNC POLICY > baked-in default" do
    # MvccConflict baked-in default = RAISE (no retry).
    # User SYNC POLICY = RETRY(2) THEN RAISE.
    # Inline ON = RETRY(7) THEN PASS.
    # The lowering should pick the highest-priority resolvable handler.

    it "no SYNC POLICY, no inline → baked-in default RAISE" do
      ast = annotate(<<~CLEAR)
        STRUCT C { v: Int64 }
        FN main() RETURNS Void ->
          c = C{ v: 0 } @versioned;
          WITH SNAPSHOT c AS MUTABLE x { x.v = 1; }
          RETURN;
        END
      CLEAR
      with_node = find_with(ast)
      # Synthesized from baked-in default.
      expect(with_node.lock_error_clause.retries).to be_nil
      expect(with_node.lock_error_clause.action).to eq(:raise)
    end

    it "user SYNC POLICY (no inline) → user's RETRY(2) THEN RAISE" do
      ast = annotate(<<~CLEAR)
        SYNC POLICY START
            ON LockTimeout RAISE
            ON MvccConflict RETRY(2) THEN RAISE
            ON AtomicConflict RAISE
        END

        STRUCT C { v: Int64 }
        FN main() RETURNS Void ->
          c = C{ v: 0 } @versioned;
          WITH SNAPSHOT c AS MUTABLE x { x.v = 1; }
          RETURN;
        END
      CLEAR
      with_node = find_with(ast)
      expect(with_node.lock_error_clause.retries).to eq(2)
      expect(with_node.lock_error_clause.action).to eq(:raise)
    end

    it "inline ON wins over user SYNC POLICY" do
      ast = annotate(<<~CLEAR)
        SYNC POLICY START
            ON LockTimeout RAISE
            ON MvccConflict RETRY(2) THEN RAISE
            ON AtomicConflict RAISE
        END

        STRUCT C { v: Int64 }
        FN main() RETURNS Void ->
          c = C{ v: 0 } @versioned;
          WITH SNAPSHOT c AS MUTABLE x { x.v = 1; } ON MvccConflict RETRY(7) THEN PASS
          RETURN;
        END
      CLEAR
      with_node = find_with(ast)
      # Inline wins (RETRY(7) THEN PASS).
      expect(with_node.lock_error_clause.retries).to eq(7)
      expect(with_node.lock_error_clause.action).to eq(:pass)
    end

    it "inline ON wins over baked-in default" do
      ast = annotate(<<~CLEAR)
        STRUCT C { v: Int64 }
        FN main() RETURNS Void ->
          c = C{ v: 0 } @versioned;
          WITH SNAPSHOT c AS MUTABLE x { x.v = 1; } ON MvccConflict RETRY(5) THEN PASS
          RETURN;
        END
      CLEAR
      with_node = find_with(ast)
      expect(with_node.lock_error_clause.retries).to eq(5)
      expect(with_node.lock_error_clause.action).to eq(:pass)
    end
  end

  # AtomicConflict path: same precedence chain, different cell type.
  describe "precedence chain for @indirect:atomic (AtomicConflict)" do
    it "no inline → baked-in default's AtomicConflict RAISE handler" do
      ast = annotate(<<~CLEAR)
        STRUCT C { v: Int64 }
        FN main() RETURNS Void ->
          MUTABLE c = C{ v: 0 } @indirect:atomic;
          WITH SNAPSHOT c AS MUTABLE x { x.v = 1; }
          RETURN;
        END
      CLEAR
      with_node = find_with(ast)
      expect(with_node.lock_error_clause).not_to be_nil
      expect(with_node.lock_error_clause.selectors.first.name).to eq(:AtomicConflict)
      expect(with_node.lock_error_clause.action).to eq(:raise)
    end

    it "user SYNC POLICY's AtomicConflict RETRY(3) THEN RAISE applies when no inline" do
      ast = annotate(<<~CLEAR)
        SYNC POLICY START
            ON LockTimeout RAISE
            ON MvccConflict RAISE
            ON AtomicConflict RETRY(3) THEN RAISE
        END

        STRUCT C { v: Int64 }
        FN main() RETURNS Void ->
          MUTABLE c = C{ v: 0 } @indirect:atomic;
          WITH SNAPSHOT c AS MUTABLE x { x.v = 1; }
          RETURN;
        END
      CLEAR
      with_node = find_with(ast)
      expect(with_node.lock_error_clause.retries).to eq(3)
    end
  end

  # ── Family rejection cross-pairs ─────────────────────────────

  describe "family rejection: cross-pair coverage" do
    # Each REQUIRES family rejects bindings outside its admission.
    # Build a parameterized fn + caller; assert the call-site error
    # for every wrong-family binding.
    REJECTION_CASES = [
      # [requires_family, binding_sigil, expected_arg_family_name]
      [:LOCKED,      "@shared:versioned",       "VERSIONED"],
      [:LOCKED,      "@shared:indirect:atomic", "ATOMIC"],
      [:VERSIONED,   "@shared:locked",   "LOCKED"],
      [:VERSIONED,   "@shared:indirect:atomic", "ATOMIC"],
      [:ATOMIC,      "@shared:locked",   "LOCKED"],
      [:ATOMIC,      "@shared:versioned",       "VERSIONED"],
      [:SNAPSHOTTED, "@shared:locked",   "LOCKED"],  # SNAPSHOTTED rejects LOCKED
    ].freeze

    REJECTION_CASES.each do |req_family, binding_sigil, expected_family|
      it "REQUIRES #{req_family} rejects a #{binding_sigil} binding (family #{expected_family})" do
        with_form = case req_family
                    when :LOCKED
                      "WITH POLYMORPHIC EXCLUSIVE c AS x { x.v = x.v + 1; }"
                    when :SNAPSHOTTED
                      # SNAPSHOTTED is poly across @versioned + @atomic; use SNAPSHOT.
                      "WITH SNAPSHOT c AS MUTABLE x { x.v = x.v + 1; }"
                    when :VERSIONED
                      "WITH SNAPSHOT c AS MUTABLE x { x.v = x.v + 1; }"
                    when :ATOMIC
                      "WITH SNAPSHOT c AS MUTABLE x { x.v = x.v + 1; }"
                    end

        src = <<~CLEAR
          STRUCT C { v: Int64 }
          FN bump!(MUTABLE c: SHARED C) RETURNS !Void
            REQUIRES c: #{req_family}
          ->
            #{with_form}
            RETURN;
          END
          FN main() RETURNS Void ->
            MUTABLE c = C{ v: 0 } #{binding_sigil};
            bump!(c);
            RETURN;
          END
        CLEAR

        expect { annotate(src) }.to raise_error(
          /family #{expected_family}.*not.*accepted|not accepted by this function/m
        )
      end
    end

    it "SNAPSHOTTED ACCEPTS @versioned (the umbrella property)" do
      expect {
        annotate(<<~CLEAR)
          STRUCT C { v: Int64 }
          FN bump!(MUTABLE c: C) RETURNS !Void
            REQUIRES c: SNAPSHOTTED
          ->
            WITH SNAPSHOT c AS MUTABLE x { x.v = x.v + 1; }
            RETURN;
          END
          FN main() RETURNS Void ->
            MUTABLE c = C{ v: 0 } @versioned;
            bump!(c);
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end

    it "SNAPSHOTTED ACCEPTS @indirect:atomic (the umbrella property)" do
      expect {
        annotate(<<~CLEAR)
          STRUCT C { v: Int64 }
          FN bump!(MUTABLE c: C) RETURNS !Void
            REQUIRES c: SNAPSHOTTED
          ->
            WITH SNAPSHOT c AS MUTABLE x { x.v = x.v + 1; }
            RETURN;
          END
          FN main() RETURNS Void ->
            MUTABLE c = C{ v: 0 } @indirect:atomic;
            bump!(c);
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end
  end

  # ── Unreachable handler detection ────────────────────────────

  describe "unreachable-handler detection" do
    it "ON LockTimeout inside SNAPSHOT-transaction → error (lock-free path can't surface LockTimeout)" do
      expect {
        annotate(<<~CLEAR)
          STRUCT C { v: Int64 }
          FN main() RETURNS Void ->
            c = C{ v: 0 } @versioned;
            WITH SNAPSHOT c AS MUTABLE x { x.v = 1; } ON LockTimeout RAISE
            RETURN;
          END
        CLEAR
      }.to raise_error(/LockTimeout.*not a possible error|not.*possible.*at this WITH|do not match any error the WITH acquire can produce/m)
    end

    it "ON AtomicConflict on a @versioned SNAPSHOT MUTABLE → error (wrong family)" do
      expect {
        annotate(<<~CLEAR)
          STRUCT C { v: Int64 }
          FN main() RETURNS Void ->
            c = C{ v: 0 } @versioned;
            WITH SNAPSHOT c AS MUTABLE x { x.v = 1; } ON AtomicConflict RAISE
            RETURN;
          END
        CLEAR
      }.to raise_error(/AtomicConflict.*not.*possible|not a possible error/m)
    end

    it "ON MvccConflict on @indirect:atomic SNAPSHOT MUTABLE → error (wrong family)" do
      expect {
        annotate(<<~CLEAR)
          STRUCT C { v: Int64 }
          FN main() RETURNS Void ->
            MUTABLE c = C{ v: 0 } @indirect:atomic;
            WITH SNAPSHOT c AS MUTABLE x { x.v = 1; } ON MvccConflict RAISE
            RETURN;
          END
        CLEAR
      }.to raise_error(/ON MvccConflict.*isn'?t valid.*@indirect:atomic|AtomicConflict.*not.*MvccConflict/m)
    end
  end

  # ── Cross-pair runtime-bridge integrity ──────────────────────

  describe "runtime-bridge integrity (no silent cross-family error propagation)" do
    it "@versioned SNAPSHOT MUTABLE emits ErrorName.MvccConflict, not AtomicConflict" do
      ast = annotate(<<~CLEAR)
        STRUCT C { v: Int64 }
        FN main() RETURNS Void ->
          c = C{ v: 0 } @versioned;
          WITH SNAPSHOT c AS MUTABLE x { x.v = 1; }
          RETURN;
        END
      CLEAR
      zig = ZigTranspiler.new.transpile_ast(ast) if ZigTranspiler.respond_to?(:transpile_ast)
      # Fall back to the regular transpile pipeline if no AST entry.
      zig ||= begin
        src = <<~CLEAR
          STRUCT C { v: Int64 }
          FN main() RETURNS Void ->
            c = C{ v: 0 } @versioned;
            WITH SNAPSHOT c AS MUTABLE x { x.v = 1; }
            RETURN;
          END
        CLEAR
        ZigTranspiler.new.transpile(src)
      end
      expect(zig).to include("ErrorName.MvccConflict")
      expect(zig).not_to include("ErrorName.AtomicConflict")
      expect(zig).to include("error.UpdateRetriesExhausted")
      expect(zig).not_to include("error.AtomicConflict")
    end

    it "@indirect:atomic SNAPSHOT MUTABLE emits ErrorName.AtomicConflict, not MvccConflict" do
      src = <<~CLEAR
        STRUCT C { v: Int64 }
        FN main() RETURNS Void ->
          MUTABLE c = C{ v: 0 } @indirect:atomic;
          WITH SNAPSHOT c AS MUTABLE x { x.v = 1; }
          RETURN;
        END
      CLEAR
      zig = ZigTranspiler.new.transpile(src)
      expect(zig).to include("ErrorName.AtomicConflict")
      expect(zig).not_to include("ErrorName.MvccConflict")
      expect(zig).to include("error.AtomicConflict")
      expect(zig).not_to include("error.UpdateRetriesExhausted")
    end
  end
end
