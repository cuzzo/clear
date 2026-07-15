# typed: false

require "rspec"
require_relative "../../ruby/ast/parser"

RSpec.describe "parsed type-syntax boundary" do
  it "returns immutable structural syntax without exposing semantic Type" do
    syntax = ClearParser.parse_type_syntax(
      "?{Symbol}[List]Tuple<Int64, String>@shared",
      file: "types.clear",
    )

    expect(syntax).to be_a(ParsedTypeSyntax)
    expect(syntax).not_to be_a(Type)
    expect(TypeExpressionPrinter.inline(syntax.expression))
      .to eq("?{Symbol}[]Tuple<Int64, String>@shared")
    expect(syntax.start_token.file).to eq("types.clear")
    expect { syntax.expression = NamedTypeExpression.new(name: :Bool) }.to raise_error(NoMethodError)
  end

  it "lowers syntax explicitly into the existing capability-aware semantic Type" do
    syntax = ClearParser.parse_type_syntax("[List]Tuple<Int64, ?String>@shared")
    semantic = TypeSyntaxLowering.lower(syntax)

    expect(semantic).to be_a(Type)
    expect(TypeExpressionPrinter.inline(semantic.shape.expression))
      .to eq("[]Tuple<Int64, ?String>@shared")
  end
end
