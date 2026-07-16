# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../ruby/backends/transpiler" unless defined?(ZigTranspiler)
require_relative "../ruby/annotator/phases/type_analysis_phase"

RSpec.describe Annotator::Phases::TypeAnalysisPhase do
  def token(value = "program")
    Lexer::Token.new(:VAR_ID, value, 1, 1)
  end

  def resolution_for(program)
    Annotator::Phases::ResolutionFacts.new(
      program: program,
      declarations: Annotator::Phases::DeclarationIndexer.index(program),
      root_scope: Scope.new,
      function_registry: Annotator::FunctionRegistry.new,
      type_names: [],
      function_names: []
    )
  end

  it "owns body typing and finalization order and rejects unresolved output" do
    program = AST::Program.new(token, [])
    resolution = resolution_for(program)
    events = []
    operations = Annotator::Phases::TypeAnalysisOperations.new(
      analyze_bodies: ->(_declarations, _program) { events << :bodies; nil },
      resolve_catches: ->(_declarations) { events << :catches; nil },
      finalize_program: lambda do |node|
        events << :program
        node.full_type = Type.new(:Void)
        nil
      end,
      finalize_auto_types: ->(_program) { events << :auto; nil }
    )

    result = described_class.run(resolution: resolution, operations: operations)

    expect(events).to eq([:bodies, :catches, :program, :auto])
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
