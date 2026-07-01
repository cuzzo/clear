require "spec_helper"

require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../ruby/annotator/phases/declaration_index" unless defined?(Annotator::Phases::DeclarationIndexer)
require_relative "../ruby/annotator/phases/signature_registration" unless defined?(Annotator::Phases::SignatureRegistration)
require_relative "../ruby/annotator/phases/type_registration" unless defined?(Annotator::Phases::TypeRegistration)
require_relative "../ruby/ast/lexer" unless defined?(Lexer)

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

    main_sig = FunctionSignature.unwrap(annotator.send(:current_scope).resolve_entry!("main").type)
    puts_sig = FunctionSignature.unwrap(annotator.send(:current_scope).resolve_entry!("puts").type)
    expect(main_sig.return_type.resolved).to eq(:Int64)
    expect(main_sig.params.map(&:name)).to eq(["x"])
    expect(puts_sig.extern).to eq(true)
    expect(puts_sig.module_alias).to eq("c")
    expect(extern_fn.full_type!.resolved).to eq(:Void)
  end

  it "rejects duplicate ordinary function declarations" do
    annotator = SemanticAnnotator.new

    expect {
      annotator.register_program_signatures(index_for(
        function_def("main"),
        function_def("main")
      ))
    }.to raise_error(CompilerError, /Duplicate function declaration 'main'/)
  end

  it "rejects duplicate free extern declarations" do
    first = AST::ExternFnDecl.new(tok("puts"), "puts", [], Type.new(:Void), "c", nil)
    second = AST::ExternFnDecl.new(tok("puts"), "puts", [], Type.new(:Void), "c", nil)
    annotator = SemanticAnnotator.new

    expect {
      annotator.register_program_signatures(index_for(first, second))
    }.to raise_error(CompilerError, /Duplicate function declaration 'puts'/)
  end

  it "allows local functions to shadow stdlib intrinsic names" do
    annotator = SemanticAnnotator.new

    annotator.register_program_signatures(index_for(function_def("positive?")))

    signature = FunctionSignature.unwrap(annotator.send(:current_scope).resolve_entry!("positive?").type)
    expect(signature).to be_a(FunctionSignature)
    expect(signature&.intrinsic).to eq(false)
  end

  it "rejects local functions that collide with imported function signatures" do
    annotator = SemanticAnnotator.new
    imported = FunctionSignature.new(
      params: [],
      return_type: Type.new(:Void),
      visibility: :pub,
      module_alias: "dep"
    )
    annotator.send(:current_scope).declare("helper", nil, imported, false, false, nil, :static)

    expect {
      annotator.register_program_signatures(index_for(function_def("helper")))
    }.to raise_error(CompilerError, /Duplicate function declaration 'helper'/)
  end

  it "rejects extern free functions that collide with imported function signatures" do
    annotator = SemanticAnnotator.new
    imported = FunctionSignature.new(
      params: [],
      return_type: Type.new(:Void),
      visibility: :pub,
      module_alias: "dep"
    )
    extern_fn = AST::ExternFnDecl.new(tok("helper"), "helper", [], Type.new(:Void), "native", nil)
    annotator.send(:current_scope).declare("helper", nil, imported, false, false, nil, :static)

    expect {
      annotator.register_program_signatures(index_for(extern_fn))
    }.to raise_error(CompilerError, /Duplicate function declaration 'helper'/)
  end

  it "registers extern methods on known type schemas and ignores unknown owners" do
    struct = AST::StructDef.new(tok("ClearParser"), "ClearParser", {}, :pub, [])
    known = AST::ExternFnDecl.new(tok("parse"), "parse", [], Type.new(:Bool), "native", nil)
    known.owner_type = "ClearParser"
    unknown = AST::ExternFnDecl.new(tok("skip"), "skip", [], Type.new(:Void), "native", nil)
    unknown.owner_type = "Missing"
    annotator = SemanticAnnotator.new

    index = index_for(struct, known, unknown)
    annotator.register_type_declarations(index)
    annotator.register_program_signatures(index)

    parser_schema = annotator.send(:current_scope).types.fetch(:ClearParser).schema
    expect(parser_schema.methods.fetch("parse")).to be_a(FunctionSignature)
    expect(annotator.send(:current_scope).entry?("parse")).to eq(false)
    expect(annotator.send(:current_scope).entry?("skip")).to eq(false)
    expect(known.full_type!.resolved).to eq(:Void)
    expect(unknown.full_type!.resolved).to eq(:Void)
  end

  it "rejects duplicate extern methods on the same owner type" do
    struct = AST::StructDef.new(tok("ClearParser"), "ClearParser", {}, :pub, [])
    first = AST::ExternFnDecl.new(tok("parse"), "parse", [], Type.new(:Bool), "native", nil)
    first.owner_type = "ClearParser"
    second = AST::ExternFnDecl.new(tok("parse"), "parse", [], Type.new(:Bool), "native", nil)
    second.owner_type = "ClearParser"
    annotator = SemanticAnnotator.new
    index = index_for(struct, first, second)

    annotator.register_type_declarations(index)

    expect {
      annotator.register_program_signatures(index)
    }.to raise_error(CompilerError, /Duplicate extern method declaration 'ClearParser.parse'/)
  end

  it "rejects extern methods that collide with existing schema methods" do
    struct = AST::StructDef.new(tok("ClearParser"), "ClearParser", {}, :pub, [])
    method = AST::ExternFnDecl.new(tok("parse"), "parse", [], Type.new(:Bool), "native", nil)
    method.owner_type = "ClearParser"
    annotator = SemanticAnnotator.new
    index = index_for(struct)
    annotator.register_type_declarations(index)
    parser_schema = annotator.send(:current_scope).types.fetch(:ClearParser).schema
    parser_schema.methods["parse"] = FunctionSignature.new(params: [], return_type: Type.new(:Bool))

    expect {
      annotator.register_program_signatures(index_for(method))
    }.to raise_error(CompilerError, /Duplicate extern method declaration 'ClearParser.parse'/)
  end

  it "registers synthesized union default method signatures after declared functions" do
    req = AST::UnionMethodRequirement.new(
      name: "describe",
      token: tok("describe"),
      visibility: :pub,
      params: [AST::UnionMethodParamRequirement.new(name: "value", type: Type.new(:Int64))],
      return_type: Type.new(:String),
      body: [AST::Literal.new(tok("default"), :STRING, "default", :stack)],
      has_default_body: true,
    )
    union = AST::UnionDef.new(tok("Choice"), "Choice", { Item: Type.new(:Int64) }, :pub)
    union.methods = [req]
    annotator = SemanticAnnotator.new

    annotator.register_program_signatures(index_for(union))

    synthetic = annotator.send(:synthetic_function_definitions).fetch(0)
    sig = FunctionSignature.unwrap(annotator.send(:current_scope).resolve_entry!("describe").type)
    expect(synthetic.name).to eq("describe")
    expect(synthetic.body.length).to eq(1)
    expect(sig.return_type.resolved).to eq(:String)
    expect(sig.params.map(&:name)).to eq(["value"])
  end
end
