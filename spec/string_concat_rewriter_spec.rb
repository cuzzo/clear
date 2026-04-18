require "rspec"
require_relative "../src/ast/lexer"
require_relative "../src/ast/parser"
require_relative "../src/annotator"
require_relative "../src/backends/string_concat_rewriter"

RSpec.describe StringConcatRewriter do
  def rewrite(src)
    tokens = Lexer.new(src).tokenize
    ast = Parser.new(tokens, src).parse
    annotator = SemanticAnnotator.new
    annotator.annotate!(ast)
    StringConcatRewriter.new.rewrite!(ast)
    ast
  end

  def find_fn(ast, name)
    ast.statements.find { |s| s.is_a?(AST::FunctionDef) && s.name == name }
  end

  describe "2-part concat stays as BinaryOp (no benefit)" do
    it "does not rewrite a + b" do
      ast = rewrite(<<~CLEAR)
        FN main() RETURNS Void ->
            s = "hello" + " world";
            RETURN;
        END
      CLEAR
      main = find_fn(ast, "main")
      bind = main.body.find { |s| s.respond_to?(:name) && s.name == "s" }
      expect(bind.value).to be_a(AST::BinaryOp)
    end
  end

  describe "3-part concat becomes StringConcat" do
    it "flattens a + b + c into StringConcat([a, b, c])" do
      ast = rewrite(<<~CLEAR)
        FN main() RETURNS Void ->
            s = "hello" + " " + "world";
            RETURN;
        END
      CLEAR
      main = find_fn(ast, "main")
      bind = main.body.find { |s| s.respond_to?(:name) && s.name == "s" }
      expect(bind.value).to be_a(AST::StringConcat)
      expect(bind.value.parts.length).to eq(3)
    end
  end

  describe "4-part concat flattens correctly" do
    it "flattens a + b + c + d into StringConcat([a, b, c, d])" do
      ast = rewrite(<<~CLEAR)
        FN greet(name: String) RETURNS String ->
            RETURN "Hello, " + name + "! " + "Welcome.";
        END
        FN main() RETURNS Void -> PASS END
      CLEAR
      fn = find_fn(ast, "greet")
      ret = fn.body.find { |s| s.is_a?(AST::ReturnNode) }
      expect(ret.value).to be_a(AST::StringConcat)
      expect(ret.value.parts.length).to eq(4)
    end
  end

  describe "numeric + is NOT rewritten" do
    it "leaves numeric addition as BinaryOp" do
      ast = rewrite(<<~CLEAR)
        FN main() RETURNS Void ->
            n = 1.0 + 2.0 + 3.0;
            RETURN;
        END
      CLEAR
      main = find_fn(ast, "main")
      bind = main.body.find { |s| s.respond_to?(:name) && s.name == "n" }
      expect(bind.value).to be_a(AST::BinaryOp)
      expect(bind.value).not_to be_a(AST::StringConcat)
    end
  end
end
