require "rspec"
require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/ast/ast"
require_relative "../src/ast/fixable_error"
require_relative "../src/backends/transpiler"

# Thunk Phase 4f.3 -- EFFECTS REENTRANT:MAX_DEPTH(N).
#
# Bounded recursion: the function asserts at runtime that depth
# never exceeds N. Beyond that, `safety.enterDepth` raises
# `error.MaxDepthExceeded` (System). Like :NOT_LOGICAL, the
# function MUST declare an error-union return type (`!T`).

RSpec.describe "Thunk Phase 4f.3 -- :MAX_DEPTH(N)" do
  def parse(source)
    tokens = Lexer.new(source).tokenize
    ClearParser.new(tokens, source).parse
  end

  def annotate(source)
    ast = parse(source)
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)
    ast
  end

  describe "parser" do
    it "accepts EFFECTS REENTRANT:MAX_DEPTH(N)" do
      ast = parse(<<~CLEAR)
        FN f(n: Int64) RETURNS !Int64
          EFFECTS REENTRANT:MAX_DEPTH(64) ->
          RETURN n + 1;
        END
      CLEAR
      fn = ast.statements.first
      expect(fn.effects_decl).to eq(:reentrant_max_depth)
      expect(fn.max_depth_n).to eq(64)
    end

    it "rejects N <= 0" do
      expect {
        parse(<<~CLEAR)
          FN f(n: Int64) RETURNS !Int64
            EFFECTS REENTRANT:MAX_DEPTH(0) ->
            RETURN n + 1;
          END
        CLEAR
      }.to raise_error(/positive integer N/)
    end

    it "saves the effects_span across the parens" do
      ast = parse(<<~CLEAR)
        FN f(n: Int64) RETURNS !Int64
          EFFECTS REENTRANT:MAX_DEPTH(64) ->
          RETURN n + 1;
        END
      CLEAR
      fn = ast.statements.first
      expect(fn.effects_span[:start_tok].value).to eq("EFFECTS")
      expect(fn.effects_span[:end_tok].value).to eq(")")
    end
  end

  describe "annotator validation" do
    it "compiles when return type is !T" do
      expect {
        annotate(<<~CLEAR)
          FN f(n: Int64) RETURNS !Int64
            EFFECTS REENTRANT:MAX_DEPTH(64) ->
            RETURN n + 1;
          END
          FN main() RETURNS Void -> _ = f(0_i64); RETURN; END
        CLEAR
      }.not_to raise_error
    end

    it "rejects bare T return (no error union)" do
      expect {
        annotate(<<~CLEAR)
          FN f(n: Int64) RETURNS Int64
            EFFECTS REENTRANT:MAX_DEPTH(64) ->
            RETURN n + 1;
          END
          FN main() RETURNS Void -> _ = f(0_i64); RETURN; END
        CLEAR
      }.to raise_error(/error-union return type.*!Int64/m)
    end

    it "stamps reentrance_kind = :reentrant_max_depth and routes through StackGuard family" do
      ast = annotate(<<~CLEAR)
        FN f(n: Int64) RETURNS !Int64
          EFFECTS REENTRANT:MAX_DEPTH(8) ->
          RETURN n + 1;
        END
        FN main() RETURNS Void -> _ = f(0_i64); RETURN; END
      CLEAR
      fn = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "f" }
      expect(fn.reentrance_kind).to eq(:reentrant_max_depth)
      expect(fn.reentrance_guard_required?).to be(true)
      expect(fn.max_depth_n).to eq(8)
    end
  end

  describe "fixable mutual-recursion error (3 options)" do
    let(:src) {
      <<~CLEAR
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
    }

    after { FixCollector.disable! }

    it "now offers three interactive migrations" do
      FixCollector.enable!
      tokens = Lexer.new(src).tokenize
      ast = ClearParser.new(tokens, src).parse
      SemanticAnnotator.new.annotate!(ast) rescue nil
      finds = FixCollector.drain.select { |f| f.category == :reentrance }
      finding = finds.first
      descriptions = finding.fixes.map(&:description)
      expect(descriptions).to include(match(/Drop ':THUNK'/))
      expect(descriptions).to include(match(/:NOT_LOGICAL/))
      expect(descriptions).to include(match(/:MAX_DEPTH\(64\)/))
    end

    it ":MAX_DEPTH fix message warns against using N as an OS-thread workaround" do
      FixCollector.enable!
      tokens = Lexer.new(src).tokenize
      ast = ClearParser.new(tokens, src).parse
      SemanticAnnotator.new.annotate!(ast) rescue nil
      finds = FixCollector.drain.select { |f| f.category == :reentrance }
      finding = finds.first
      md_fix = finding.fixes.find { |fx| fx.description.include?(":MAX_DEPTH") }
      expect(md_fix.description).to match(/PICK N TIGHT|not a workaround.*OS threads/)
    end
  end
end
