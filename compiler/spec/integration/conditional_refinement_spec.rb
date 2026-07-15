# typed: false

require "rspec"
require_relative "../../ruby/ast/parser"
require_relative "../../ruby/annotator"

RSpec.describe "frontend conditional-refinement integration" do
  def frontend(source)
    ast = ClearParser.new(Lexer.new(source).tokenize, source).parse
    SemanticAnnotator.new(source_code: source).annotate!(ast)
    ast
  end

  def main_with(condition)
    <<~CLEAR
      FN main(maybe: ?Int64, result: !Int64, enabled: Bool) RETURNS Void ->
        IF #{condition} THEN
          PASS;
        END
      END
    CLEAR
  end

  {
    "plain then EXISTS capture" => "enabled AND maybe EXISTS AS value AND value > 0_i64",
    "EXISTS capture then plain" => "maybe EXISTS AS value AND enabled AND value > 0_i64",
    "plain then IS_OK capture" => "enabled AND result IS_OK AS value AND value > 0_i64",
    "IS_OK capture then plain" => "result IS_OK AS value AND enabled AND value > 0_i64",
    "parenthesized capture" => "enabled AND (maybe EXISTS AS value) AND value > 0_i64",
  }.each do |label, condition|
    it("accepts #{label}") { expect { frontend(main_with(condition)) }.not_to raise_error }
  end

  [
    "maybe EXISTS AS value OR enabled",
    "enabled OR maybe EXISTS AS value",
    "(maybe EXISTS AS value) OR enabled",
  ].each do |condition|
    it "rejects the non-definite capture in #{condition}" do
      expect { frontend(main_with(condition)) }
        .to raise_error(ParserError, /not definite beneath `OR`/)
    end
  end

  it "normalizes a mixed chain to the equivalent nested control-flow shape" do
    mixed = frontend(main_with("enabled AND maybe EXISTS AS value AND value > 0_i64"))
    outer = mixed.statements.first.body.first
    expect(outer).to be_a(AST::IfStatement)
    bind = outer.then_branch.first
    expect(bind).to be_a(AST::IfBind)
    expect(bind.bindings.map(&:name)).to eq(["value"])
    expect(bind.then_branch.first).to be_a(AST::IfStatement)
  end
end
