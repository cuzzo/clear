# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../ruby/annotator/phases/resolution_phase"

RSpec.describe Annotator::Phases::ResolutionPhase do
  it "keeps the mutable resolution session behind two explicit operations" do
    public_operations = Annotator::Phases::ResolutionSession.public_instance_methods(false) - Object.public_instance_methods

    expect(public_operations).to contain_exactly(:resolve!, :register_local_declaration!)
  end

  it "owns resolution ordering without traversing function bodies" do
    source = <<~CLEAR
      STRUCT Box { value: Int64 }

      FN main() RETURNS Int64 ->
        RETURN missing_name;
      END
    CLEAR
    program = ClearParser.new(Lexer.new(source).tokenize, source).parse

    result = described_class.run(program: program, importer: nil, source_dir: Dir.pwd, source_code: source)

    expect(result.function_names).to include("main")
    expect(result.type_names).to include(:Box)
    expect(result.function_registry.nodes).to be_empty
  end

  it "registers a late extern through the local-declaration operation" do
    session = Annotator::Phases::ResolutionSession.new(
      importer: nil, source_dir: Dir.pwd, source_code: nil, install_builtins: false
    )
    extern = AST::ExternFnDecl.new(nil, "native_len", [], Type.new(:Int64), "native", nil)

    session.register_local_declaration!(extern)

    scope = session.resolve!(AST::Program.new(nil, [])).root_scope
    expect(scope.resolve_entry!("native_len").fn_signature&.extern).to eq(true)
    expect(extern.full_type!.resolved).to eq(:Void)
  end

  it "publishes real compiler resolution facts before body typing" do
    source = <<~CLEAR
      STRUCT Box { value: Int64 }

      FN identity(value: Int64) RETURNS Int64 ->
        RETURN value;
      END
    CLEAR
    ast = ClearParser.new(Lexer.new(source).tokenize, source).parse
    annotator = SemanticAnnotator.new(source_code: source)

    annotator.annotate!(ast)
    resolution = annotator.annotation_products.resolution

    expect(resolution).to be_a(Annotator::Phases::ResolutionFacts)
    expect(T.must(resolution).type_names).to include(:Box)
    expect(T.must(resolution).function_names).to include("identity")
    expect(T.must(resolution).declarations.function_declarations.map(&:name)).to eq(["identity"])
  end
end
