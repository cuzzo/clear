# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../ruby/semantic/semantic_index"

RSpec.describe SemanticIndex do
  def token
    Lexer::Token.new(:VAR_ID, "program", 1, 1)
  end

  def phase_products(violation_count: 0, publish_audit: true)
    program = AST::Program.new(token, [])
    program.full_type = Type.new(:Void)
    resolution = Annotator::Phases::ResolutionFacts.new(
      program: program,
      declarations: Annotator::Phases::DeclarationIndexer.index(program),
      root_scope: Scope.new,
      function_registry: Annotator::FunctionRegistry.new,
      type_names: [],
      function_names: []
    )
    typed = Annotator::Phases::TypedProgramFacts.new(
      resolution: resolution,
      body_summaries: {},
      typed_node_count: 1,
      unresolved_node_count: 0,
      ownership_graph: OwnershipGraph.new
    )
    audit = Annotator::Phases::CapabilityAuditReport.new(
      typed_program: typed,
      derived_program: Annotator::Phases::DerivedProgramFacts.empty,
      checked_functions: [],
      checked_call_sites: 0,
      checked_with_sites: 0,
      violation_count: violation_count
    )
    products = Annotator::Phases::AnnotationProducts.new
    products = products.publish_resolution(resolution)
    products = products.publish_typed_program(typed)
    products = products.publish_capability_audit(audit) if publish_audit
    products
  end

  it "rejects incomplete, unsuccessful, and mutable phase ledgers" do
    id_index = Semantic::SemanticIdIndex.new(definitions: {}, bodies: {})
    incomplete = phase_products(publish_audit: false)
    unsuccessful = phase_products(violation_count: 1)
    mutable = phase_products.dup

    expect { described_class.from_products(annotation_products: incomplete, id_index: id_index) }
      .to raise_error(/complete annotation products/)
    expect { described_class.from_products(annotation_products: unsuccessful, id_index: id_index) }
      .to raise_error(/successful capability audit/)
    expect { described_class.from_products(annotation_products: mutable, id_index: id_index) }
      .to raise_error(/frozen annotation product ledger/)
  end
end
