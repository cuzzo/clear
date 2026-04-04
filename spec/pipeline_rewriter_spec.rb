require "rspec"
require_relative "../src/lexer"
require_relative "../src/parser"
require_relative "../src/annotator"
require_relative "../src/pipeline_rewriter"

RSpec.describe PipelineRewriter do
  def rewrite(src)
    tokens = Lexer.new(src).tokenize
    ast = Parser.new(tokens, src).parse
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)
    PipelineRewriter.new.rewrite!(ast)
    ast
  end

  def find_fn(ast, name)
    ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == name }
  end

  describe "simple function pipe: x s> f" do
    it "rewrites to FuncCall(f, [x])" do
      ast = rewrite(<<~CLEAR)
        FN double(n: Float64) RETURNS Float64 -> RETURN n * 2.0; END
        FN main() RETURNS Void ->
            x = 5.0;
            result = x s> double;
            RETURN;
        END
      CLEAR
      main = find_fn(ast, "main")
      bind = main.body.find { |s| s.respond_to?(:name) && s.name == "result" }
      expect(bind.value).to be_a(AST::FuncCall)
      expect(bind.value.name).to eq("double")
      expect(bind.value.args.length).to eq(1)
    end
  end

  describe "function pipe with args: x s> f(y)" do
    it "rewrites to FuncCall(f, [x, y])" do
      ast = rewrite(<<~CLEAR)
        FN add(a: Float64, b: Float64) RETURNS Float64 -> RETURN a + b; END
        FN main() RETURNS Void ->
            x = 5.0;
            result = x s> add(3.0);
            RETURN;
        END
      CLEAR
      main = find_fn(ast, "main")
      bind = main.body.find { |s| s.respond_to?(:name) && s.name == "result" }
      expect(bind.value).to be_a(AST::FuncCall)
      expect(bind.value.name).to eq("add")
      expect(bind.value.args.length).to eq(2)
    end
  end

  describe "chained pipes: x s> f s> g" do
    it "rewrites both pipes bottom-up" do
      ast = rewrite(<<~CLEAR)
        FN double(n: Float64) RETURNS Float64 -> RETURN n * 2.0; END
        FN negate(n: Float64) RETURNS Float64 -> RETURN 0.0 - n; END
        FN main() RETURNS Void ->
            x = 5.0;
            result = x s> double s> negate;
            RETURN;
        END
      CLEAR
      main = find_fn(ast, "main")
      bind = main.body.find { |s| s.respond_to?(:name) && s.name == "result" }
      # Should be negate(double(x)) - outer call is negate
      expect(bind.value).to be_a(AST::FuncCall)
      expect(bind.value.name).to eq("negate")
      inner = bind.value.args[0]
      expect(inner).to be_a(AST::FuncCall)
      expect(inner.name).to eq("double")
    end
  end

  describe "pipeline operators (WHERE, SELECT, etc.) are preserved" do
    it "does not rewrite WHERE - leaves for transpiler" do
      ast = rewrite(<<~CLEAR)
        FN check(n: Float64) RETURNS Bool -> RETURN n > 0.0; END
        FN main() RETURNS Void ->
            MUTABLE items: Float64[]@list = List[];
            items.append(1.0);
            result = items s> WHERE(check);
            RETURN;
        END
      CLEAR
      main = find_fn(ast, "main")
      bind = main.body.find { |s| s.respond_to?(:name) && s.name == "result" }
      # Should still be BinaryOp(:SMOOTH) with WhereOp RHS
      expect(bind.value).to be_a(AST::BinaryOp)
      expect(bind.value.op).to eq(:SMOOTH)
    end
  end
end
