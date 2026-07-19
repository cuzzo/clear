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

  it "supports the single-statement arrow form" do
    source = <<~CLEAR
      FN main(maybe: ?Int64, enabled: Bool) RETURNS Void ->
        IF enabled AND maybe EXISTS AS value -> PASS;
      END
    CLEAR

    expect { frontend(source) }.not_to raise_error
  end

  it "supports a refinement chain in an ELSE_IF arm" do
    source = <<~CLEAR
      FN main(maybe: ?Int64, enabled: Bool) RETURNS Void ->
        IF enabled THEN
          PASS;
        ELSE_IF enabled AND maybe EXISTS AS value AND value > 0_i64 THEN
          PASS;
        END
      END
    CLEAR

    expect { frontend(source) }.not_to raise_error
  end

  it "supports ELSE_IF after a refined first arm" do
    source = <<~CLEAR
      FN main(maybe: ?Int64, enabled: Bool) RETURNS Void ->
        IF enabled AND maybe EXISTS AS value THEN
          PASS;
        ELSE_IF enabled THEN
          PASS;
        END
      END
    CLEAR

    expect { frontend(source) }.not_to raise_error
  end

  it "preserves a grouped Boolean atom before a later capture" do
    ["(enabled OR enabled)", "(enabled AND enabled)"].each do |group|
      expect { frontend(main_with("#{group} AND maybe EXISTS AS value")) }
        .not_to raise_error
    end
  end

  it "narrows an optional on the short-circuit right edge of OR" do
    source = <<~CLEAR
      FN marker_is_absent_or_zero(marker: ?Int64) RETURNS Bool ->
        RETURN marker == NIL OR marker.zero?();
      END
    CLEAR

    expect { frontend(source) }.not_to raise_error
  end

  it "narrows optional comparisons through nested short-circuit conditions" do
    source = <<~CLEAR
      FN marker_is_usable(text: String, marker: ?Int64) RETURNS Bool ->
        RETURN !(text.contains?("<") OR marker == NIL OR marker.zero?());
      END

      FN positive(marker: ?Int64) RETURNS Bool ->
        RETURN marker != NIL AND marker > 0_i64;
      END
    CLEAR

    expect { frontend(source) }.not_to raise_error
  end

  it "carries non-nil facts into conditional branches" do
    source = <<~CLEAR
      FN add_present(left: ?Int64, right: ?Int64) RETURNS Int64 ->
        IF left != NIL AND right != NIL THEN
          RETURN left + right;
        END
        RETURN 0_i64;
      END

      FN zero_or_value(value: ?Int64) RETURNS Int64 ->
        IF value == NIL THEN
          RETURN 0_i64;
        ELSE
          RETURN value;
        END
      END
    CLEAR

    expect { frontend(source) }.not_to raise_error
  end

  it "joins a concrete and optional IF-expression branch as optional" do
    source = <<~CLEAR
      FN choose(enabled: Bool, fallback: ?Int64) RETURNS ?Int64 ->
        RETURN IF enabled THEN 1_i64 ELSE fallback END;
      END
    CLEAR

    expect { frontend(source) }.not_to raise_error
  end

  it "rejects a capture nested inside a grouped OR atom" do
    expect { frontend(main_with("enabled AND (maybe EXISTS AS value OR enabled)")) }
      .to raise_error(ParserError, /not definite beneath `OR`/)
    expect { frontend(main_with("enabled AND ((maybe EXISTS AS value) OR enabled)")) }
      .to raise_error(ParserError, /not definite beneath `OR`/)
  end


  it "accepts an expression statement while stamping the enclosing source range" do
    source = <<~CLEAR
      FN main() RETURNS Void ->
        1_i64;
      END
    CLEAR

    expect { frontend(source) }.not_to raise_error
  end

  it "survives annotation, cleanup classification, and the MIR frontend" do
    source = <<~CLEAR
      FN choose(maybe: ?Int64, enabled: Bool) RETURNS Int64 ->
        IF enabled AND maybe EXISTS AS value AND value > 0_i64 THEN
          RETURN value;
        ELSE
          RETURN 0_i64;
        END
      END
    CLEAR

    result = compile_mir_frontend(source)
    expect(result.ast.statements.first).to be_a(AST::FunctionDef)
  end
end
