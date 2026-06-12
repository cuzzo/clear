require "rspec"
require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/ast/ast"
require_relative "../src/ast/fixable_error"
require_relative "../src/backends/transpiler"

# A directly-recursive (or mutually-recursive) function without an
# explicit reentrance declaration used to raise REENTRANCE_DIRECT_RECURSIVE
# or REENTRANCE_INDIRECT_RECURSIVE with
# no fix. Both now emit a FixableFinding whose :auto fix inserts
# `EFFECTS REENTRANT ` before the function arrow.
RSpec.describe "Reentrant function auto-fix" do
  before { FixCollector.enable! }
  after  { FixCollector.disable! }

  def annotate(source)
    tokens = Lexer.new(source).tokenize
    ast = Parser.new(tokens, source).parse
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  describe "direct self-recursion without reentrance declaration" do
    let(:src) {
      <<~CLEAR
        FN factorial(n: Int64) RETURNS Int64 ->
            IF n <= 1 THEN RETURN 1; END
            RETURN n * factorial(n - 1);
        END
        FN main() RETURNS Void -> END
      CLEAR
    }

    it "captures a fixable finding with a single :auto fix" do
      annotate(src) rescue nil
      findings = FixCollector.drain.select { |f| f.message =~ /'factorial'.*recursi/i }
      expect(findings.size).to eq(1)
      expect(findings.first.fixes.first.confidence).to eq(:auto)
    end

    it "produces an edit inserting `EFFECTS REENTRANT ` before the arrow" do
      annotate(src) rescue nil
      finding = FixCollector.drain.find { |f| f.message =~ /recursi/i }
      edit = finding.fixes.first.edits.first
      expect(edit.replacement).to eq("EFFECTS REENTRANT ")
      expect(edit.span.length).to eq(0)  # zero-length insertion
      expect(edit.span.line).to eq(1)
      # `FN factorial(n: Int64) RETURNS Int64 ->`
      # The arrow `->` starts at column 38; insertion goes there.
      expect(edit.span.col).to eq(38)
    end

    it "applying the fix produces compilable CLEAR" do
      fixed = src.sub("RETURNS Int64 ->", "RETURNS Int64 EFFECTS REENTRANT ->")
      expect { annotate(fixed) }.not_to raise_error
    end
  end

  describe "mutual recursion (transitive cycle)" do
    let(:src) {
      <<~CLEAR
        FN isEven(n: Int64) RETURNS Bool ->
            IF n == 0 THEN RETURN TRUE; END
            RETURN isOdd(n - 1);
        END
        FN isOdd(n: Int64) RETURNS Bool ->
            IF n == 0 THEN RETURN FALSE; END
            RETURN isEven(n - 1);
        END
        FN main() RETURNS Void -> END
      CLEAR
    }

    it "captures fixable findings for the cycle members" do
      annotate(src) rescue nil
      findings = FixCollector.drain.select { |f| f.message =~ /recursi/i }
      expect(findings.size).to be >= 1
      expect(findings.first.fixes.first.confidence).to eq(:auto)
      expect(findings.first.fixes.first.edits.first.replacement).to eq("EFFECTS REENTRANT ")
    end
  end

  describe "fallback when arrow_token is missing" do
    it "raises plain CompilerError when the fix isn't locatable" do
      src = <<~CLEAR
        FN factorial(n: Int64) RETURNS Int64 ->
            IF n <= 1 THEN RETURN 1; END
            RETURN n * factorial(n - 1);
        END
        FN main() RETURNS Void -> END
      CLEAR
      tokens = Lexer.new(src).tokenize
      ast = Parser.new(tokens, src).parse
      factorial = ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == "factorial" }
      factorial.arrow_token = nil
      ann = SemanticAnnotator.new
      FixCollector.disable!
      expect { ann.annotate!(ast) }.to raise_error(CompilerError, /recursi/i)
    end
  end
end
