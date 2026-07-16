# typed: strict
require "sorbet-runtime"

require_relative "../ast/ast"
require_relative "../ast/scope"
require_relative "../annotator/function_registry"
require_relative "../annotator/phases/annotation_products"
require_relative "../annotator/phases/body_analysis"
require_relative "semantic_ids"

class SemanticIndex < T::Struct
  extend T::Sig

  const :program, AST::Program
  const :root_scope, Scope
  const :function_registry, Annotator::FunctionRegistry
  const :id_index, Semantic::SemanticIdIndex
  const :annotation_products, Annotator::Phases::AnnotationProducts

  sig do
    params(
      annotation_products: Annotator::Phases::AnnotationProducts,
      id_index: Semantic::SemanticIdIndex
    ).returns(SemanticIndex)
  end
  def self.from_products(annotation_products:, id_index:)
    resolution = annotation_products.resolution
    typed_program = annotation_products.typed_program
    audit = annotation_products.capability_audit

    raise "semantic index requires complete annotation products" unless resolution && typed_program && audit
    raise "semantic index requires a successful capability audit" unless audit.success?
    raise "semantic index requires a frozen annotation product ledger" unless annotation_products.frozen?

    new(
      program: resolution.program,
      root_scope: resolution.root_scope,
      function_registry: resolution.function_registry,
      id_index: id_index,
      annotation_products: annotation_products
    ).freeze
  end

  sig { returns(Annotator::Phases::TypedProgramFacts) }
  def typed_program
    T.must(annotation_products.typed_program)
  end

  sig { returns(Annotator::Phases::CapabilityAuditReport) }
  def capability_audit
    T.must(annotation_products.capability_audit)
  end

  sig { returns(T::Hash[String, AST::FunctionDef]) }
  def function_nodes
    function_registry.nodes
  end

  sig { params(name: String).returns(T.nilable(AST::FunctionDef)) }
  def function_node(name)
    function_registry.fetch(name)
  end

  sig { returns(T::Hash[String, Annotator::Phases::FunctionBodySummary]) }
  def body_summaries
    typed_program.body_summaries
  end
end
