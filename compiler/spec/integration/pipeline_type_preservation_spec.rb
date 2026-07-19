# typed: false

require "rspec"
require_relative "../../ruby/ast/parser"
require_relative "../../ruby/annotator"

RSpec.describe "pipeline type preservation" do
  def frontend(source)
    ast = ClearParser.new(Lexer.new(source).tokenize, source).parse
    SemanticAnnotator.new(source_code: source).annotate!(ast)
    ast
  end

  it "constructs the canonical Set type and preserves element capabilities through DISTINCT" do
    source = <<~CLEAR
      FN main() RETURNS Void ->
        MUTABLE resource_types: [Set]String@symbol = [:File, :Directory] |> DISTINCT _;
      END
    CLEAR

    ast = frontend(source)
    declaration = ast.statements.first.body.first
    result_type = declaration.value.full_type

    expect(result_type.collection).to eq(:set)
    expect(result_type.shape.expression).to be_a(LinearTypeExpression)
    expect(result_type.shape.expression.kind).to eq(:set)
    expect(result_type.element_type.sync).to eq(:symbol)
  end
end
