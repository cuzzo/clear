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
end
