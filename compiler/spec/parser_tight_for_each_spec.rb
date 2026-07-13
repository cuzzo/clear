require "rspec"
require_relative "../ruby/ast/lexer" unless defined?(Lexer)
require_relative "../ruby/ast/parser" unless defined?(ClearParser)

RSpec.describe "TIGHT FOR EACH parsing" do
  it "accepts a collection iterator as well as a numeric range" do
    source = <<~CLEAR
      FN main() RETURNS Void ->
        values: Int64[] = [1_i64, 2_i64];
        TIGHT FOR value IN values DO
          print(value);
        END
      END
    CLEAR

    ast = ClearParser.new(Lexer.new(source).tokenize, source).parse
    loop = ast.statements.fetch(0).body.fetch(1)

    expect(loop).to be_a(AST::ForEach)
    expect(loop.tight).to be(true)
  end
end
