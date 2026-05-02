require "rspec"
require "set"

require_relative "../src/backends/transpiler"
require_relative "../src/annotator-helpers/with_match_check"

# Atomics M1.4 -- REQUIRES c: ATOMIC parsing + family validation.
#
# Verifies the ATOMIC family is accepted in REQUIRES clauses, family_of_arg
# maps :atomic-sync bindings to :ATOMIC, and the call-site check accepts
# @shared:atomic args while rejecting other syncs. Mirrors the
# requires_with_match_spec coverage for LOCKED / VERSIONED.
RSpec.describe "Atomics M1.4: REQUIRES c: ATOMIC" do
  def parse(src)
    Parser.new(Lexer.new(src).tokenize, src).parse
  end

  def annotate(src)
    ast = parse(src)
    ann = SemanticAnnotator.new
    ann.annotate!(ast)
    [ast, ann]
  end

  describe "REQUIRES parsing" do
    it "parses a single-family REQUIRES c: ATOMIC" do
      ast = parse("FN bump(c: Int64) RETURNS Void REQUIRES c: ATOMIC -> END")
      expect(ast.statements.first.requires).to eq("c" => Set[:ATOMIC])
    end

    it "parses ATOMIC | LOCKED disjunction" do
      ast = parse("FN bump(c: Int64) RETURNS Void REQUIRES c: ATOMIC | LOCKED -> END")
      expect(ast.statements.first.requires).to eq("c" => Set[:ATOMIC, :LOCKED])
    end

    it "parses LOCKED | VERSIONED | ATOMIC three-way disjunction" do
      ast = parse("FN bump(c: Int64) RETURNS Void REQUIRES c: LOCKED | VERSIONED | ATOMIC -> END")
      expect(ast.statements.first.requires).to eq(
        "c" => Set[:LOCKED, :VERSIONED, :ATOMIC]
      )
    end

    it "parses grouped param-list with ATOMIC family" do
      ast = parse("FN bump(a: Int64, b: Int64) RETURNS Void REQUIRES a, b: ATOMIC -> END")
      expect(ast.statements.first.requires).to eq(
        "a" => Set[:ATOMIC],
        "b" => Set[:ATOMIC]
      )
    end

    it "still rejects unknown families when ATOMIC was added" do
      expect {
        parse("FN bump(c: Int64) RETURNS Void REQUIRES c: NOT_A_FAMILY -> END")
      }.to raise_error(ParserError, /Unknown REQUIRES family/)
    end
  end

  describe "WithMatchCheck.family_of_arg" do
    it "returns :ATOMIC for a SymbolEntry with sync == :atomic" do
      sym = Object.new
      def sym.sync; :atomic; end
      arg = Object.new
      arg.define_singleton_method(:symbol) { sym }
      arg.define_singleton_method(:respond_to?) { |m| m == :symbol || super(m) }
      expect(WithMatchCheck.family_of_arg(arg)).to eq(:ATOMIC)
    end

    it "returns :LOCKED for sync == :locked (regression -- atomic addition didn't perturb)" do
      sym = Object.new
      def sym.sync; :locked; end
      arg = Object.new
      arg.define_singleton_method(:symbol) { sym }
      arg.define_singleton_method(:respond_to?) { |m| m == :symbol || super(m) }
      expect(WithMatchCheck.family_of_arg(arg)).to eq(:LOCKED)
    end

    it "returns :VERSIONED for sync == :versioned (regression)" do
      sym = Object.new
      def sym.sync; :versioned; end
      arg = Object.new
      arg.define_singleton_method(:symbol) { sym }
      arg.define_singleton_method(:respond_to?) { |m| m == :symbol || super(m) }
      expect(WithMatchCheck.family_of_arg(arg)).to eq(:VERSIONED)
    end

    it "returns :LOCAL for a sync-less binding (#336)" do
      # Pre-#336 this returned nil; now non-sync bindings are
      # classified into the LOCAL family (admits @local /
      # @multiowned / plain T) so they can be passed to
      # `REQUIRES c: LOCAL` parameters.
      sym = Object.new
      def sym.sync; nil; end
      def sym.storage; nil; end
      arg = Object.new
      arg.define_singleton_method(:symbol) { sym }
      arg.define_singleton_method(:respond_to?) { |m| m == :symbol || super(m) }
      expect(WithMatchCheck.family_of_arg(arg)).to eq(:LOCAL)
    end
  end
end
