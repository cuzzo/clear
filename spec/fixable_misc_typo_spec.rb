require "rspec"
require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/ast/ast"
require_relative "../src/ast/fixable_error"
require_relative "../src/backends/transpiler"

# BG / DO branch prefix sigil typos + struct/type-name typos.
#
# UNKNOWN_LITERAL is defensive (literal-token-typo at lexer level —
# user can't author it) and UNION_METHOD_MISSING / inline-variant
# unknown-field aren't typo cases (the former is missing
# implementation, the latter would need parser plumbing for per-
# field tokens). Those are excluded from this batch.
RSpec.describe "BG / branch / type typo auto-fixes" do
  before { FixCollector.enable! }
  after  { FixCollector.disable! }

  def parse(source)
    tokens = Lexer.new(source).tokenize
    Parser.new(tokens, source).parse
  end

  def annotate(source)
    ast = parse(source)
    SemanticAnnotator.new.annotate!(ast)
    ast
  end

  describe "UNKNOWN_BG_PREFIX — `@srvice` typo for `@service`" do
    let(:src) {
      <<~CLEAR
        FN main() RETURNS Void ->
          fut = BG { @srvice -> _ = 1; };
          _ = NEXT fut;
        END
      CLEAR
    }
    it "suggests @service" do
      parse(src) rescue nil
      finding = FixCollector.drain.find { |f| f.message =~ /@srvice/ }
      expect(finding).not_to be_nil
      expect(finding.fixes.first.edits.first.replacement).to eq("@service")
    end
  end

  describe "UNKNOWN_BRANCH_PREFIX — `@parralel` typo for `@parallel`" do
    let(:src) {
      <<~CLEAR
        FN main() RETURNS Void ->
          DO {
            @parralel _ = 1;,
            _ = 2;
          }
        END
      CLEAR
    }
    it "suggests @parallel" do
      parse(src) rescue nil
      finding = FixCollector.drain.find { |f| f.message =~ /@parralel/ }
      expect(finding).not_to be_nil
      expect(finding.fixes.first.edits.first.replacement).to eq("@parallel")
    end
  end

  describe "UNKNOWN_STRUCT_TYPE — `Pont` typo for `Point`" do
    let(:src) {
      <<~CLEAR
        STRUCT Point { x: Int64, y: Int64 }
        FN main() RETURNS Void ->
          p = Pont{x: 1, y: 2};
          _ = p;
        END
      CLEAR
    }
    it "suggests Point" do
      annotate(src) rescue nil
      finding = FixCollector.drain.find { |f| f.message =~ /'Pont'/ }
      expect(finding).not_to be_nil
      expect(finding.fixes.first.edits.first.replacement).to eq("Point")
    end
  end

  describe "UNKNOWN_TYPE — generic `Pir<Int64>` typo for `Pair`" do
    let(:src) {
      <<~CLEAR
        STRUCT Pair<T> { first: T, second: T }
        FN main() RETURNS Void ->
          p = Pir<Int64>{first: 1, second: 2};
          _ = p;
        END
      CLEAR
    }
    it "suggests Pair" do
      annotate(src) rescue nil
      finding = FixCollector.drain.find { |f| f.message =~ /'Pir'/ }
      expect(finding).not_to be_nil
      expect(finding.fixes.first.edits.first.replacement).to eq("Pair")
    end
  end
end
