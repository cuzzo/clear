require "rspec"
require_relative "../src/ast/lexer" unless defined?(Lexer)
require_relative "../src/ast/parser" unless defined?(ClearParser)
require_relative "../src/annotator" unless defined?(SemanticAnnotator)
require_relative "../src/mir/rewriters/string_concat_rewriter" unless defined?(StringConcatRewriter)

RSpec.describe StringConcatRewriter do
  def token
    @token ||= Lexer.new('"x"').tokenize.first
  end

  def string_literal(value)
    AST::Literal.new(token, :STRING, value, nil).tap do |node|
      node.full_type = Type.new(:String)
    end
  end

  def ident(name)
    AST::Identifier.new(token, name).tap do |node|
      node.full_type = Type.new(:String)
    end
  end

  def string_plus(left, right, marked: true)
    AST::BinaryOp.new(token, left, :ADD, right).tap do |node|
      node.string_concat = marked
      node.full_type = Type.new(:String)
    end
  end

  def long_concat
    string_plus(string_plus(string_literal("a"), ident("name")), string_literal("z"))
  end

  def rewriter
    described_class.new
  end

  def rewrite(src)
    tokens = Lexer.new(src).tokenize
    ast = ClearParser.new(tokens, src).parse
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
        FN greet(name: String) RETURNS !String ->
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

  describe "direct AST traversal" do
    it "rewrites top-level program statements and returns the statement array" do
      assignment = AST::Assignment.new(token, "s", long_concat)
      program = AST::Program.new(token, [assignment])

      result = rewriter.rewrite!(program)

      expect(result).to eq([assignment])
      expect(assignment.value).to be_a(AST::StringConcat)
      expect(assignment.value.parts.map(&:class)).to eq([AST::Literal, AST::Identifier, AST::Literal])
    end

    it "leaves nil and non-concat nodes unchanged" do
      literal = string_literal("plain")

      expect(rewriter.send(:rewrite_in_node!, nil)).to be_nil
      expect(rewriter.send(:rewrite_in_node!, literal)).to equal(literal)
      expect(rewriter.send(:string_concat?, literal)).to eq(false)
      expect(rewriter.send(:string_concat?, string_plus(string_literal("a"), string_literal("b"), marked: false))).to eq(false)
    end

    it "recognizes existing StringConcat nodes and reuses their parts" do
      parts = [string_literal("a"), ident("b")]
      node = AST::StringConcat.new(token, parts)
      node.full_type = Type.new(:String)

      expect(rewriter.send(:string_concat?, node)).to eq(true)
      expect(rewriter.send(:collect_parts, node)).to equal(parts)
    end

    it "does not collect parts from unmarked binary operations" do
      node = string_plus(string_literal("a"), string_literal("b"), marked: false)

      expect(rewriter.send(:collect_parts, node)).to eq([node])
    end

    it "rewrites function, conditional, loop, and match bodies" do
      function_return = AST::ReturnNode.new(token, long_concat)
      if_assignment = AST::Assignment.new(token, "if_s", long_concat)
      while_return = AST::ReturnNode.new(token, long_concat)
      for_return = AST::ReturnNode.new(token, long_concat)
      each_return = AST::ReturnNode.new(token, long_concat)
      match_return = AST::ReturnNode.new(token, long_concat)
      default_return = AST::ReturnNode.new(token, long_concat)
      match_case = AST::MatchCase.new(kind: :literal, value: string_literal("case"), body: [match_return])
      match = AST::MatchStatement.new(token, ident("subject"), [match_case], [default_return], [], [], true, nil)
      if_node = AST::IfStatement.new(token, ident("ok"), [if_assignment], [match], nil, nil)
      while_node = AST::WhileLoop.new(token, ident("keep_going"), [while_return], [])
      for_range = AST::ForRange.new(token, "i", string_literal("a"), string_literal("z"), true, [for_return], [], nil)
      for_each = AST::ForEach.new(token, "item", ident("items"), [each_return], [], false)
      fn = AST::FunctionDef.new(token, "demo", [], [], Type.new(:Void), nil, [function_return, if_node, while_node, for_range, for_each], [], nil, :public, [], false)

      rewriter.send(:rewrite_in_node!, fn)

      expect(function_return.value).to be_a(AST::StringConcat)
      expect(if_assignment.value).to be_a(AST::StringConcat)
      expect(while_return.value).to be_a(AST::StringConcat)
      expect(for_return.value).to be_a(AST::StringConcat)
      expect(each_return.value).to be_a(AST::StringConcat)
      expect(match_return.value).to be_a(AST::StringConcat)
      expect(default_return.value).to be_a(AST::StringConcat)
    end

    it "rewrites call arguments, method arguments, struct fields, and binary operands" do
      func_call = AST::FuncCall.new(token, "takes_string", [long_concat])
      method_call = AST::MethodCall.new(token, ident("receiver"), "takes_string", [long_concat])
      struct_lit = AST::StructLit.new(token, "Box", {"name" => long_concat}, nil, [])
      binary = AST::BinaryOp.new(token, long_concat, :EQ, long_concat)
      var_decl = AST::VarDecl.new(token, "declared", Type.new(:String), long_concat, false)
      bind_expr = AST::BindExpr.new(token, "bound", Type.new(:String), long_concat)

      [func_call, method_call, struct_lit, binary, var_decl, bind_expr].each { |node| rewriter.send(:rewrite_in_node!, node) }

      expect(func_call.args.first).to be_a(AST::StringConcat)
      expect(method_call.args.first).to be_a(AST::StringConcat)
      expect(method_call.object).to be_a(AST::Identifier)
      expect(struct_lit.fields.fetch("name")).to be_a(AST::StringConcat)
      expect(binary.left).to be_a(AST::StringConcat)
      expect(binary.right).to be_a(AST::StringConcat)
      expect(var_decl.value).to be_a(AST::StringConcat)
      expect(bind_expr.value).to be_a(AST::StringConcat)
    end

    it "replaces raw expression statements inside node body arrays" do
      fn = AST::FunctionDef.new(token, "demo", [], [], Type.new(:Void), nil, [long_concat], [], nil, :public, [], false)
      if_node = AST::IfStatement.new(token, ident("ok"), [long_concat], [long_concat], nil, nil)
      match_case = AST::MatchCase.new(kind: :literal, value: string_literal("case"), body: [long_concat])
      match = AST::MatchStatement.new(token, ident("subject"), [match_case], [long_concat], [], [], true, nil)
      while_node = AST::WhileLoop.new(token, ident("keep_going"), [long_concat], [])
      for_range = AST::ForRange.new(token, "i", string_literal("a"), string_literal("z"), true, [long_concat], [], nil)
      for_each = AST::ForEach.new(token, "item", ident("items"), [long_concat], [], false)

      [fn, if_node, match, while_node, for_range, for_each].each { |node| rewriter.send(:rewrite_in_node!, node) }

      expect(fn.body.first).to be_a(AST::StringConcat)
      expect(if_node.then_branch.first).to be_a(AST::StringConcat)
      expect(if_node.else_branch.first).to be_a(AST::StringConcat)
      expect(match.cases.first.body.first).to be_a(AST::StringConcat)
      expect(match.default_case.first).to be_a(AST::StringConcat)
      expect(while_node.do_branch.first).to be_a(AST::StringConcat)
      expect(for_range.body.first).to be_a(AST::StringConcat)
      expect(for_each.body.first).to be_a(AST::StringConcat)
    end

    it "tolerates optional empty child locations" do
      if_node = AST::IfStatement.new(token, ident("ok"), nil, nil, nil, nil)
      match = AST::MatchStatement.new(token, ident("subject"), [], nil, [], nil, true, nil)
      while_node = AST::WhileLoop.new(token, ident("keep_going"), AST::ReturnNode.new(token, nil), [])

      expect { rewriter.send(:rewrite_in_node!, if_node) }.not_to raise_error
      expect { rewriter.send(:rewrite_in_node!, match) }.not_to raise_error
      expect { rewriter.send(:rewrite_in_node!, while_node) }.not_to raise_error
    end

    it "preserves token, type, and storage metadata on synthetic concat nodes" do
      node = long_concat
      node.storage = :heap

      result = rewriter.send(:rewrite_in_node!, node)

      expect(result).to be_a(AST::StringConcat)
      expect(result.token).to equal(node.token)
      expect(result.full_type.raw).to eq(:String)
      expect(result.storage).to eq(:heap)
    end

    it "keeps two-part string additions as binary operations" do
      left = string_literal("head")
      right = ident("tail")
      node = string_plus(left, right)

      result = rewriter.send(:rewrite_in_node!, node)

      expect(result).to be_a(AST::BinaryOp)
      expect(result.left).to equal(left)
      expect(result.right).to equal(right)
    end
  end
end
