require "spec_helper"

require_relative "../src/annotator/phases/declaration_index" unless defined?(Annotator::Phases::DeclarationIndexer)
require_relative "../src/ast/lexer" unless defined?(Lexer)

RSpec.describe Annotator::Phases::DeclarationIndexer do
  def tok(value = "x")
    Lexer::Token.new(:VAR_ID, value, 1, 1)
  end

  def function_def(name)
    AST::FunctionDef.new(tok(name), name, [], [], nil, nil, [], [], nil, :pub, [], false)
  end

  it "classifies top-level declarations once in program order buckets" do
    require_node = AST::RequireNode.new(tok("require"), "math", "math", :file)
    struct_def = AST::StructDef.new(tok("Point"), "Point", {}, :pub, [])
    enum_def = AST::EnumDef.new(tok("Mode"), "Mode", ["On"], :pub)
    extern_struct = AST::ExternStructDecl.new(tok("Native"), "Native", {}, "native")
    union_with_methods = AST::UnionDef.new(tok("Choice"), "Choice", { "A" => nil }, :pub)
    union_with_methods.methods = [{ name: "value" }]
    fn = function_def("main")
    extern_fn = AST::ExternFnDecl.new(tok("puts"), "puts", [], Type.new(:Void), "c", {})
    body_stmt = AST::VarDecl.new(tok("x"), "x", Type.new(:Int64), nil, false)
    program = AST::Program.new(tok("program"), [
      require_node, struct_def, enum_def, extern_struct, union_with_methods,
      fn, extern_fn, body_stmt
    ])

    index = described_class.index(program)

    expect(index.imports).to eq([require_node])
    expect(index.type_declarations).to eq([struct_def, enum_def, extern_struct, union_with_methods])
    expect(index.function_declarations).to eq([fn])
    expect(index.extern_function_declarations).to eq([extern_fn])
    expect(index.union_method_declarations).to eq([union_with_methods])
    expect(index.body_statements).to eq([fn, body_stmt])
  end

  it "does not schedule unions without method requirements for method validation" do
    union_without_methods = AST::UnionDef.new(tok("Plain"), "Plain", { "A" => nil }, :pub)
    union_with_empty_methods = AST::UnionDef.new(tok("Empty"), "Empty", { "A" => nil }, :pub)
    union_with_empty_methods.methods = []
    program = AST::Program.new(tok("program"), [union_without_methods, union_with_empty_methods])

    index = described_class.index(program)

    expect(index.type_declarations).to eq([union_without_methods, union_with_empty_methods])
    expect(index.union_method_declarations).to eq([])
    expect(index.body_statements).to eq([])
  end

  it "does not inspect function bodies while indexing declarations" do
    raise_node = AST::Raise.new(tok("RAISE"), :System, "DeclaredInBody", nil)
    exit_node = AST::OrExit.new(tok("OR"), :Input, "DeclaredInCatch", nil)
    catch_clause = AST::CatchClause.new(body: [exit_node])
    fn = function_def("main")
    fn.body = [raise_node]
    fn.catch_clauses = [catch_clause]
    program = AST::Program.new(tok("program"), [fn])

    index = described_class.index(program)

    expect(index.function_declarations).to eq([fn])
    expect(index.body_statements).to eq([fn])
  end
end
