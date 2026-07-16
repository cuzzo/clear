# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../ruby/annotator/phases/annotation_products"

RSpec.describe Annotator::Phases::AnnotationProducts do
  def token(value = "program")
    Lexer::Token.new(:VAR_ID, value, 1, 1)
  end

  def resolution_facts
    program = AST::Program.new(token, [])
    declarations = Annotator::Phases::DeclarationIndexer.index(program)
    Annotator::Phases::ResolutionFacts.new(
      program: program,
      declarations: declarations,
      root_scope: Scope.new,
      function_registry: Annotator::FunctionRegistry.new,
      type_names: [:Box],
      function_names: ["main"]
    )
  end

  it "publishes the three immutable products in dependency order" do
    products = described_class.new
    resolution = resolution_facts
    typed = Annotator::Phases::TypedProgramFacts.new(
      resolution: resolution,
      body_summaries: {},
      typed_node_count: 1,
      unresolved_node_count: 0
    )
    audit = Annotator::Phases::CapabilityAuditReport.new(
      typed_program: typed,
      checked_functions: ["main"],
      checked_call_sites: 0,
      checked_with_sites: 0,
      violation_count: 0
    )

    products = products.publish_resolution(resolution)
    products = products.publish_typed_program(typed)
    products = products.publish_capability_audit(audit)

    expect(products).to be_complete
    expect(products).to be_frozen
    expect(audit).to be_success
    expect(resolution.type_names).to be_frozen
    expect(typed.body_summaries).to be_frozen
    expect(audit.checked_functions).to be_frozen
    expect { products.publish_capability_audit(audit) }.to raise_error(/already published/)
  end

  it "rejects skipped, repeated, mismatched, and incomplete phase products" do
    products = described_class.new
    resolution = resolution_facts
    other_resolution = resolution_facts
    typed = Annotator::Phases::TypedProgramFacts.new(
      resolution: resolution,
      body_summaries: {},
      typed_node_count: 0,
      unresolved_node_count: 0
    )
    mismatched = Annotator::Phases::TypedProgramFacts.new(
      resolution: other_resolution,
      body_summaries: {},
      typed_node_count: 0,
      unresolved_node_count: 0
    )

    expect { products.publish_typed_program(typed) }.to raise_error(/requires resolution/)
    products = products.publish_resolution(resolution)
    expect { products.publish_resolution(resolution) }.to raise_error(/already published/)
    expect { products.publish_typed_program(mismatched) }.to raise_error(/different resolution/)
    expect {
      Annotator::Phases::TypedProgramFacts.new(
        resolution: resolution,
        body_summaries: {},
        typed_node_count: 1,
        unresolved_node_count: 1
      )
    }.to raise_error(/unresolved nodes/)
  end
end
