require "rspec"
require_relative "../src/lexer"
require_relative "../src/parser"
require_relative "../src/pipeline_rewriter"

# PipelineRewriter is currently a no-op placeholder.
# Pipeline s> carries error-unwrapping semantics that require annotation.
# All pipeline handling stays in the annotator + transpiler pipeline_generator.

RSpec.describe PipelineRewriter do
  def parse_and_rewrite(src)
    tokens = Lexer.new(src).tokenize
    ast = Parser.new(tokens, src).parse
    PipelineRewriter.new.rewrite!(ast)
    ast
  end

  it "preserves pipeline nodes for the annotator (no-op)" do
    ast = parse_and_rewrite(<<~CLEAR)
      FN double(n: Float64) RETURNS Float64 -> RETURN n * 2.0; END
      FN main() RETURNS Void ->
          x = 5.0;
          result = x s> double;
          RETURN;
      END
    CLEAR
    main = ast.statements.find { |s| s.respond_to?(:name) && s.name == "main" }
    bind = main.body.find { |s| s.respond_to?(:name) && s.name == "result" }
    expect(bind.value).to be_a(AST::BinaryOp)
    expect(bind.value.op).to eq(:SMOOTH)
  end
end
