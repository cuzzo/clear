require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)
require_relative "../ruby/ast/ast" unless defined?(MIR::ReassignPlan)
require_relative "../ruby/ast/fixable_error" unless defined?(FixCollector)
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)

# Thunk Phase 4g -- per-variant stack-tier dispatch + @service
# explicit-declaration requirement for plain :reentrant.

RSpec.describe "Thunk Phase 4g -- stack sizing per reentrance kind" do
  def annotate(source)
    tokens = Lexer.new(source).tokenize
    ast = ClearParser.new(tokens, source).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  def fn_named(ast, name)
    ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == name }
  end

  describe ":reentrant_thunk does NOT force OS thread" do
    it "stack_tier is bounded (not :unbounded)" do
      ast = annotate(<<~CLEAR)
        FN factorial(n: Int64) RETURNS Int64
          EFFECTS REENTRANT:THUNK ->
          IF n <= 1 -> RETURN 1;
          RETURN n * factorial(n - 1);
        END
        FN main() RETURNS Void -> _ = factorial(5_i64); RETURN; END
      CLEAR
      fn = fn_named(ast, "factorial")
      expect(fn.stack_tier).not_to eq(:unbounded)
      expect([:micro, :standard, :large, :xl]).to include(fn.stack_tier)
    end

    it "BG that calls a :THUNK fn does NOT require @service" do
      expect {
        annotate(<<~CLEAR)
          FN factorial(n: Int64) RETURNS Int64
            EFFECTS REENTRANT:THUNK ->
            IF n <= 1 -> RETURN 1;
            RETURN n * factorial(n - 1);
          END
          FN main() RETURNS Void ->
            p: ~Int64 = BG { factorial(5_i64); };
            _ = NEXT p;
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end
  end

  describe ":reentrant_tail_call does NOT force OS thread" do
    it "stack_tier is bounded" do
      ast = annotate(<<~CLEAR)
        FN sum(n: Int64, acc: Int64) RETURNS Int64
          EFFECTS REENTRANT:TAIL_CALL ->
          IF n <= 0 -> RETURN acc;
          RETURN sum(n - 1, acc + n);
        END
        FN main() RETURNS Void -> _ = sum(10_i64, 0_i64); RETURN; END
      CLEAR
      fn = fn_named(ast, "sum")
      expect(fn.stack_tier).not_to eq(:unbounded)
    end

    it "BG calling a :TAIL_CALL fn does NOT require @service" do
      expect {
        annotate(<<~CLEAR)
          FN sum(n: Int64, acc: Int64) RETURNS Int64
            EFFECTS REENTRANT:TAIL_CALL ->
            IF n <= 0 -> RETURN acc;
            RETURN sum(n - 1, acc + n);
          END
          FN main() RETURNS Void ->
            p: ~Int64 = BG { sum(10_i64, 0_i64); };
            _ = NEXT p;
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end
  end

  describe ":reentrant_max_depth(N) is bounded by N" do
    it "stack_tier reflects frame * N (single-self case)" do
      ast = annotate(<<~CLEAR)
        FN bounded(n: Int64) RETURNS !Int64
          EFFECTS REENTRANT:MAX_DEPTH(8) ->
          RETURN n + 1;
        END
        FN main() RETURNS Void -> _ = bounded(0_i64); RETURN; END
      CLEAR
      fn = fn_named(ast, "bounded")
      expect(fn.stack_tier).not_to eq(:unbounded)
      expect(fn.max_depth_n).to eq(8)
    end

    it "BG calling a :MAX_DEPTH fn does NOT require @service" do
      expect {
        annotate(<<~CLEAR)
          FN bounded(n: Int64) RETURNS !Int64
            EFFECTS REENTRANT:MAX_DEPTH(8) ->
            RETURN n + 1;
          END
          FN main() RETURNS Void ->
            p: ~Int64 = BG { bounded(0_i64) OR_ELSE EXIT System, "x"; };
            _ = NEXT p;
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end
  end

  describe "plain EFFECTS REENTRANT requires explicit @service" do
    it "BG without @service errors" do
      expect {
        annotate(<<~CLEAR)
          FN fib(n: Int64) RETURNS Int64
            EFFECTS REENTRANT ->
            IF n <= 1 -> RETURN n;
            RETURN fib(n - 1) + fib(n - 2);
          END
          FN main() RETURNS Void ->
            p: ~Int64 = BG { fib(10_i64); };
            _ = NEXT p;
            RETURN;
          END
        CLEAR
      }.to raise_error(/Declare `@service` explicitly/)
    end

    it "BG with @service compiles" do
      expect {
        annotate(<<~CLEAR)
          FN fib(n: Int64) RETURNS Int64
            EFFECTS REENTRANT ->
            IF n <= 1 -> RETURN n;
            RETURN fib(n - 1) + fib(n - 2);
          END
          FN main() RETURNS Void ->
            p: ~Int64 = BG { @service -> fib(10_i64); };
            _ = NEXT p;
            RETURN;
          END
        CLEAR
      }.not_to raise_error
    end

    it "@canSmash on a fiber is rejected as not-yet-supported (v0.3 reserved)" do
      expect {
        annotate(<<~CLEAR)
          FN fib(n: Int64) RETURNS Int64
            EFFECTS REENTRANT ->
            IF n <= 1 -> RETURN n;
            RETURN fib(n - 1) + fib(n - 2);
          END
          FN main() RETURNS Void ->
            p: ~Int64 = BG { @canSmash -> fib(10_i64); };
            _ = NEXT p;
            RETURN;
          END
        CLEAR
      }.to raise_error(/`@canSmash`.*not yet supported.*v0\.3/m)
    end
  end

  describe "mutual :MAX_DEPTH falls back to OS thread" do
    it "BG without @service errors with the mutual-MAX_DEPTH message" do
      expect {
        annotate(<<~CLEAR)
          FN a(n: Int64) RETURNS !Int64
            EFFECTS REENTRANT:MAX_DEPTH(8) ->
            RETURN b(n);
          END
          FN b(n: Int64) RETURNS !Int64
            EFFECTS REENTRANT:MAX_DEPTH(8) ->
            RETURN a(n);
          END
          FN main() RETURNS Void ->
            p: ~Int64 = BG { a(4_i64) OR_ELSE EXIT System, "x"; };
            _ = NEXT p;
            RETURN;
          END
        CLEAR
      }.to raise_error(/MAX_DEPTH.*mutually recursive|mutual depth-bounds compose|product across counters|OS thread/m)
    end
  end

  describe "fixable error suggests both @service-replace and @service-insert" do
    after { FixCollector.disable! }

    it "no-prefix BG: fix description says 'Insert `@service ->` after `{`'" do
      FixCollector.enable!
      src = <<~CLEAR
        FN fib(n: Int64) RETURNS Int64
          EFFECTS REENTRANT ->
          IF n <= 1 -> RETURN n;
          RETURN fib(n - 1) + fib(n - 2);
        END
        FN main() RETURNS Void ->
          p: ~Int64 = BG { fib(10_i64); };
          _ = NEXT p;
          RETURN;
        END
      CLEAR
      tokens = Lexer.new(src).tokenize
      ast = ClearParser.new(tokens, src).parse
      SemanticAnnotator.new.annotate!(ast) rescue nil
      finds = FixCollector.drain.select { |f| f.category == :reentrance }
      expect(finds).not_to be_empty
      finding = finds.first
      expect(finding.message).to match(/Declare `@service`/)
      expect(finding.fixes.first.description).to match(/Insert `@service ->`/)
    end

    it "wrong-prefix BG: fix description says 'Replace `@<x>` with `@service`'" do
      FixCollector.enable!
      src = <<~CLEAR
        FN fib(n: Int64) RETURNS Int64
          EFFECTS REENTRANT ->
          IF n <= 1 -> RETURN n;
          RETURN fib(n - 1) + fib(n - 2);
        END
        FN main() RETURNS Void ->
          p: ~Int64 = BG { @standard -> fib(10_i64); };
          _ = NEXT p;
          RETURN;
        END
      CLEAR
      tokens = Lexer.new(src).tokenize
      ast = ClearParser.new(tokens, src).parse
      SemanticAnnotator.new.annotate!(ast) rescue nil
      finds = FixCollector.drain.select { |f| f.category == :reentrance }
      finding = finds.first
      expect(finding.fixes.first.description).to match(/Replace `@standard`/)
    end
  end
end
