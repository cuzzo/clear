require "rspec"
require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/ast/ast"
require_relative "../src/backends/transpiler"

# Thunk Phase 4f -- mutual recursion validation.
#
# Phase 4f's validation pass distinguishes three buckets of
# `:reentrant_thunk` functions and emits a precise error message
# per bucket so users know exactly which sub-phase will (or
# won't) support their shape:
#
#   1. Not recursive at all -> "Remove ':THUNK'."
#   2. Directly self-recursive -> handled by Phase 4a-d (factorial shape)
#   3. Mutually recursive only -> "tagged-union codegen lands later"
#
# Tagged-union frame codegen for case 3 is deferred to a later
# sub-phase; this commit lands the detection + clear messaging.

RSpec.describe "Thunk mutual-recursion validation" do
  def annotate(source)
    tokens = Lexer.new(source).tokenize
    ast = Parser.new(tokens, source).parse
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)
    ast
  end

  describe "directly self-recursive :THUNK" do
    it "compiles via Phase 4d codegen (factorial-shape)" do
      expect {
        annotate(<<~CLEAR)
          FN factorial(n: Int64) RETURNS Int64
            EFFECTS REENTRANT:THUNK ->
            IF n <= 1 -> RETURN 1;
            RETURN n * factorial(n - 1);
          END
          FN main() RETURNS Void -> _ = factorial(5_i64); RETURN; END
        CLEAR
      }.not_to raise_error
    end

    it "compiles via Phase 4b routing (tail-recursive sum)" do
      expect {
        annotate(<<~CLEAR)
          FN sum(n: Int64, acc: Int64) RETURNS Int64
            EFFECTS REENTRANT:THUNK ->
            IF n <= 0 -> RETURN acc;
            RETURN sum(n - 1, acc + n);
          END
          FN main() RETURNS Void -> _ = sum(10_i64, 0_i64); RETURN; END
        CLEAR
      }.not_to raise_error
    end
  end

  describe "tail-position mutually-recursive :THUNK (Phase 4f.1)" do
    it "compiles via tagged-union codegen (is_even / is_odd)" do
      # Canonical mutual recursion. Both members tail-call the
      # partner with no combine op; Phase 4f.1 lifts the prior
      # error and stamps mutual_thunk_plan on each.
      ast = nil
      expect {
        ast = annotate(<<~CLEAR)
          FN is_even(n: Int64) RETURNS Bool
            EFFECTS REENTRANT:THUNK ->
            IF n == 0 -> RETURN TRUE;
            RETURN is_odd(n - 1);
          END
          FN is_odd(n: Int64) RETURNS Bool
            EFFECTS REENTRANT:THUNK ->
            IF n == 0 -> RETURN FALSE;
            RETURN is_even(n - 1);
          END
          FN main() RETURNS Void -> _ = is_even(4_i64); RETURN; END
        CLEAR
      }.not_to raise_error
      members = ast.statements.select { |s| s.is_a?(AST::FunctionDef) && %w[is_even is_odd].include?(s.name) }
      expect(members.length).to eq(2)
      members.each do |fn|
        expect(fn.mutual_thunk_plan).not_to be_nil
        expect(fn.mutual_thunk_plan.cycle_fns.map(&:name)).to contain_exactly("is_even", "is_odd")
      end
    end

    it "compiles a generic 2-cycle (a / b)" do
      expect {
        annotate(<<~CLEAR)
          FN a(n: Int64) RETURNS Int64
            EFFECTS REENTRANT:THUNK ->
            IF n <= 0 -> RETURN 0;
            RETURN b(n - 1);
          END
          FN b(n: Int64) RETURNS Int64
            EFFECTS REENTRANT:THUNK ->
            IF n <= 0 -> RETURN 0;
            RETURN a(n - 1);
          END
          FN main() RETURNS Void -> _ = a(4_i64); RETURN; END
        CLEAR
      }.not_to raise_error
    end
  end

  describe "non-tail mutually-recursive :THUNK" do
    it "still errors with the forward-pointing message" do
      # The recursive partner call is nested inside a binary op,
      # so it's NOT in tail position. The tagged-union codegen
      # doesn't handle this shape; Phase 4f.2's fixable error
      # fires (offering 'EFFECTS REENTRANT' or ':NOT_LOGICAL').
      expect {
        annotate(<<~CLEAR)
          FN a(n: Int64) RETURNS Int64
            EFFECTS REENTRANT:THUNK ->
            IF n <= 0 -> RETURN 1;
            RETURN n * b(n - 1);
          END
          FN b(n: Int64) RETURNS Int64
            EFFECTS REENTRANT:THUNK ->
            IF n <= 0 -> RETURN 1;
            RETURN n * a(n - 1);
          END
          FN main() RETURNS Void -> _ = a(4_i64); RETURN; END
        CLEAR
      }.to raise_error(/mutually recursive.*EFFECTS REENTRANT:NOT_LOGICAL/m)
    end
  end

  describe "non-recursive :THUNK" do
    it "errors with 'not recursive'" do
      expect {
        annotate(<<~CLEAR)
          FN noop(n: Int64) RETURNS Int64
            EFFECTS REENTRANT:THUNK ->
            RETURN n + 1;
          END
          FN main() RETURNS Void -> _ = noop(5_i64); RETURN; END
        CLEAR
      }.to raise_error(/not recursive \(neither direct nor mutual\)/)
    end
  end
end
