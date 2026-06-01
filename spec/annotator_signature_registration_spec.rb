require "spec_helper"

require_relative "../src/backends/transpiler"
require_relative "../src/annotator/phases/declaration_index"
require_relative "../src/annotator/phases/signature_registration"
require_relative "../src/annotator/phases/type_registration"
require_relative "../src/ast/lexer"

RSpec.describe Annotator::Phases::SignatureRegistration do
  def tok(value = "x")
    Lexer::Token.new(:VAR_ID, value, 1, 1)
  end

  def function_def(name, return_type: Type.new(:Void), params: [])
    AST::FunctionDef.new(tok(name), name, params, [], return_type, nil, [], [], nil, :pub, [], false)
  end

  def param(name, type)
    AST::Param.new(name: name, type: type, default: nil, mutable: false, takes: false)
  end

  def index_for(*nodes)
    Annotator::Phases::DeclarationIndexer.index(AST::Program.new(tok("program"), nodes))
  end

  it "registers ordinary function and extern free-function signatures" do
    fn = function_def("main", return_type: Type.new(:Int64), params: [param("x", Type.new(:Int64))])
    extern_fn = AST::ExternFnDecl.new(tok("puts"), "puts", [param("msg", Type.new(:String))], Type.new(:Void), "c", nil)
    annotator = SemanticAnnotator.new

    annotator.register_program_signatures(index_for(fn, extern_fn))

    main_sig = FunctionSignature.unwrap(annotator.current_scope.locals.fetch("main").type)
    puts_sig = FunctionSignature.unwrap(annotator.current_scope.locals.fetch("puts").type)
    expect(main_sig.return_type.resolved).to eq(:Int64)
    expect(main_sig.params.map(&:name)).to eq(["x"])
    expect(puts_sig.extern).to eq(true)
    expect(puts_sig.module_alias).to eq("c")
    expect(extern_fn.full_type!.resolved).to eq(:Void)
  end

  it "registers extern methods on known type schemas and ignores unknown owners" do
    struct = AST::StructDef.new(tok("Parser"), "Parser", {}, :pub, [])
    known = AST::ExternFnDecl.new(tok("parse"), "parse", [], Type.new(:Bool), "native", nil)
    known.owner_type = "Parser"
    unknown = AST::ExternFnDecl.new(tok("skip"), "skip", [], Type.new(:Void), "native", nil)
    unknown.owner_type = "Missing"
    annotator = SemanticAnnotator.new

    index = index_for(struct, known, unknown)
    annotator.register_type_declarations(index)
    annotator.register_program_signatures(index)

    parser_schema = annotator.current_scope.types.fetch(:Parser).fetch(:schema)
    expect(parser_schema.methods.fetch("parse")).to be_a(FunctionSignature)
    expect(annotator.current_scope.locals).not_to have_key("parse")
    expect(annotator.current_scope.locals).not_to have_key("skip")
    expect(known.full_type!.resolved).to eq(:Void)
    expect(unknown.full_type!.resolved).to eq(:Void)
  end

  it "registers synthesized union default method signatures after declared functions" do
    req = {
      name: "describe",
      token: tok("describe"),
      visibility: :pub,
      params: [param("value", Type.new(:Int64))],
      return_type: Type.new(:String),
      body: [AST::Literal.new(tok("default"), :STRING, "default", :stack)],
    }
    union = AST::UnionDef.new(tok("Choice"), "Choice", { Item: Type.new(:Int64) }, :pub)
    union.methods = [req]
    annotator = SemanticAnnotator.new

    annotator.register_program_signatures(index_for(union))

    synthetic = annotator.send(:synthetic_function_definitions).fetch(0)
    sig = FunctionSignature.unwrap(annotator.current_scope.locals.fetch("describe").type)
    expect(synthetic.name).to eq("describe")
    expect(synthetic.body.length).to eq(1)
    expect(sig.return_type.resolved).to eq(:String)
    expect(sig.params.map(&:name)).to eq(["value"])
  end
end
