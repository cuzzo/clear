# typed: false

require "rspec"
require_relative "../../ruby/ast/parser"

RSpec.describe "frontend source-range integration" do
  it "preserves file identity and half-open ranges on tokens and nested AST nodes" do
    source = "\nFN main() RETURNS Int64 ->\n  value = 41_i64 + 1_i64;\n  RETURN value;\nEND\n"
    budget = FrontendResourceBudget.new
    tokens = Lexer.new(source, file: "range.clear", budget: budget).tokenize
    ast = ClearParser.new(tokens, source, budget: budget).parse
    fn = ast.statements.first
    assignment = fn.body.first
    expression = assignment.value

    expect(expression.source_range.file).to eq("range.clear")
    expect(source.byteslice(expression.source_range.start_offset...expression.source_range.end_offset))
      .to eq("41_i64 + 1_i64")
    expect(source.byteslice(assignment.source_range.start_offset...assignment.source_range.end_offset))
      .to eq("value = 41_i64 + 1_i64;")
    expect([assignment.source_range.start_line, assignment.source_range.start_column]).to eq([3, 3])
    expect([assignment.source_range.end_line, assignment.source_range.end_column]).to eq([3, 26])
  end

  it "provides a compatible range for legacy tokens without explicit endpoints" do
    token = Lexer::Token.new(:VAR_ID, "name", 4, 7)
    node = AST::Identifier.new(token, "name")

    expect(node.source_range).to have_attributes(
      start_offset: 0,
      end_offset: 4,
      start_line: 4,
      start_column: 7,
      end_line: 4,
      end_column: 11,
    )
  end

  it "stamps parsed nodes when a legacy token stream has no explicit end coordinates" do
    source = "value = 1_i64;"
    tokens = Lexer.new(source).tokenize
    tokens.each do |token|
      token.end_offset = nil
      token.end_line = nil
      token.end_column = nil
    end

    assignment = ClearParser.new(tokens, source).parse.statements.first
    expect(assignment.source_range.end_column).to eq(15)
  end
end
