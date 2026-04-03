require "rspec"
require_relative "../src/lexer"
require_relative "../src/parser"
require_relative "../src/annotator"
require_relative "../src/transpiler"

# Tests that container access (HashMap get, pool indexing) of non-Copy
# union types marks the binding as a container borrow.

RSpec.describe "Container borrow semantics" do
  def annotate(src)
    tokens = Lexer.new(src).tokenize
    ast = Parser.new(tokens, src).parse
    ann = SemanticAnnotator.new
    ann.annotate!(ast)
    [ast, ann]
  end

  def transpile(src)
    ZigTranspiler.new.transpile(src)
  end

  # =========================================================================
  # HashMap indexing of non-Copy union sets container_borrow on the type
  # =========================================================================
  it "marks HashMap get result as container_borrow" do
    src = <<~CLEAR
      STRUCT Env { x: Int64 }
      UNION Value { Nil, Num: Float64, Str: String, Lambda { body: Value @indirect, id: Int64 } }
      FN test!(MUTABLE pool: Env[10]@pool, MUTABLE map: HashMap<Value>) RETURNS Void ->
          pool.insert(Env{ x: 1 });
          val = map["key"] OR Value.Nil;
          RETURN;
      END
    CLEAR
    ast, _ann = annotate(src)
    fn = ast.statements.find { |n| n.is_a?(AST::FunctionDef) && n.name == "test!" }
    # Find the val binding
    val_decl = fn.body.find { |n| (n.is_a?(AST::VarDecl) || n.is_a?(AST::BindExpr)) && n.name.to_s == "val" }
    expect(val_decl).not_to be_nil
    expect(val_decl.type_info&.container_borrow).to be_truthy
  end

  # =========================================================================
  # Pool indexing sets container_borrow
  # =========================================================================
  it "marks pool indexing result as container_borrow" do
    src = <<~CLEAR
      STRUCT Env { vars: HashMap<Float64> }
      FN test!(MUTABLE pool: Env[10]@pool) RETURNS Void ->
          env = pool[0_u64];
          RETURN;
      END
    CLEAR
    ast, _ann = annotate(src)
    fn = ast.statements.find { |n| n.is_a?(AST::FunctionDef) && n.name == "test!" }
    env_decl = fn.body.find { |n| (n.is_a?(AST::VarDecl) || n.is_a?(AST::BindExpr)) && n.name.to_s == "env" }
    expect(env_decl).not_to be_nil
    expect(env_decl.type_info&.container_borrow).to be_truthy
  end
end
