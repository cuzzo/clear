# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../ruby/annotator/phases/type_analysis_phase"

RSpec.describe Annotator::Phases::TypeAnalysisPhase do
  def token(value = "program")
    Lexer::Token.new(:VAR_ID, value, 1, 1)
  end

  it "keeps mutable type-analysis state behind one explicit operation" do
    public_operations = Annotator::Phases::TypeAnalysisSession.public_instance_methods - Object.public_instance_methods

    expect(public_operations).to contain_exactly(:execute_type_analysis!)
  end

  it "runs directly on a phase-owned session and rejects unresolved output" do
    source = ""
    program = ClearParser.new(Lexer.new(source).tokenize, source).parse
    resolution = Annotator::Phases::ResolutionPhase.run(
      program: program,
      importer: nil,
      source_dir: Dir.pwd,
      source_code: source
    )
    session = Annotator::Phases::TypeAnalysisSession.new(source_code: source)

    result = described_class.run(resolution: resolution, session: session).typed_program

    expect(result.resolution).to equal(resolution)
    expect(result.typed_node_count).to eq(1)
    expect(result.unresolved_node_count).to eq(0)
  end

  it "publishes complete type facts from real CLEAR body analysis" do
    source = <<~CLEAR
      FN identity(value: Int64) RETURNS Int64 ->
        copy = value;
        RETURN copy;
      END
    CLEAR
    ast = ClearParser.new(Lexer.new(source).tokenize, source).parse
    annotator = SemanticAnnotator.new(source_code: source)

    annotator.annotate!(ast)
    products = annotator.annotation_products
    typed_program = products.typed_program

    expect(typed_program).to be_a(Annotator::Phases::TypedProgramFacts)
    expect(T.must(typed_program).resolution).to equal(products.resolution)
    expect(T.must(typed_program).typed_node_count).to be > 0
    expect(T.must(typed_program).unresolved_node_count).to eq(0)
    expect(T.must(typed_program).body_summaries.keys).to include("identity")
  end

  it "reports source-located unresolved nodes independently of the annotator" do
    program = AST::Program.new(token, [])

    inventory = Annotator::Phases::AnnotationTypeInventory.scan(program)

    expect(inventory.unresolved_node_count).to eq(1)
    expect(inventory.violations.first.location).to eq("1:1")
    expect(inventory.violations.first.type_name).to eq("Untyped")
  end
end
