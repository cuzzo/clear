# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "../ast/ast"
require_relative "../semantic/semantic_ids"
require_relative "../semantic/semantic_index"
require_relative "phases/annotation_boundary"
require_relative "phases/annotation_pipeline"
require_relative "phases/type_analysis_session"

# Stable compiler-facing facade. It coordinates the three annotation phases
# and exposes only completed semantic products; traversal state lives in the
# short-lived TypeAnalysisSession created by AnnotationPipeline.
class SemanticAnnotator
  extend T::Sig

  class Config < T::Struct
    const :importer, T.nilable(ModuleImporter)
    const :source_dir, String
    const :strict_test, T::Boolean
    const :source_code, T.nilable(String)
  end

  sig { returns(Annotator::Phases::AnnotationProducts) }
  attr_reader :annotation_products
  sig { returns(T.nilable(SemanticIndex)) }
  attr_reader :semantic_index

  sig do
    params(
      importer: T.nilable(ModuleImporter),
      compiler: T.nilable(ModuleImporter),
      source_dir: T.nilable(String),
      strict_test: T::Boolean,
      source_code: T.nilable(String)
    ).void
  end
  def initialize(importer: nil, compiler: nil, source_dir: nil, strict_test: false, source_code: nil)
    @config = T.let(Config.new(
      importer: importer || compiler,
      source_dir: source_dir ? File.expand_path(source_dir) : Dir.pwd,
      strict_test: strict_test,
      source_code: source_code
    ), Config)
    @annotation_products = T.let(Annotator::Phases::AnnotationProducts.new, Annotator::Phases::AnnotationProducts)
    @semantic_index = T.let(nil, T.nilable(SemanticIndex))
  end

  sig { params(program: AST::Program).void }
  def annotate!(program)
    AST.reset_user_types!
    @semantic_index = nil
    pipeline = Annotator::Phases::AnnotationPipeline.new(
      importer: @config.importer,
      source_dir: @config.source_dir,
      source_code: @config.source_code,
      strict_test: @config.strict_test
    )
    begin
      pipeline.run(program)
    ensure
      @annotation_products = pipeline.products
    end
    raise "annotation pipeline did not publish complete products" unless @annotation_products.complete?

    @semantic_index = SemanticIndex.from_products(
      annotation_products: @annotation_products,
      id_index: semantic_id_index
    )
    Annotator::Phases::AnnotationBoundary.verify!(program, @annotation_products)
  end

  sig { returns(Scope) }
  def semantic_root_scope
    index = @semantic_index
    return index.root_scope if index

    resolution = @annotation_products.resolution
    raise "semantic root scope is unavailable before resolution" unless resolution

    resolution.root_scope
  end

  sig { params(name: Symbol).returns(T.untyped) }
  def lookup_type_schema(name)
    base_name = name.to_s.sub(/<.*>$/, "").to_sym
    semantic_root_scope.resolve_type_definition(base_name)
  end

  private

  sig { returns(Semantic::SemanticIdIndex) }
  def semantic_id_index
    typed_program = T.must(@annotation_products.typed_program)
    summaries = typed_program.body_summaries
    Semantic::SemanticIdIndex.new(
      definitions: summaries.transform_values(&:definition_id),
      bodies: summaries.transform_values(&:body_id)
    )
  end

  ReceiverState = Annotator::Phases::TypeAnalysisSession::TraversalState
  HeldLockEntry = Annotator::Phases::TypeAnalysisSession::HeldLockEntry
  HeldLockTypeEntry = Annotator::Phases::TypeAnalysisSession::HeldLockTypeEntry
  DeadlockEscape = T.type_alias { Annotator::Phases::TypeAnalysisSession::DeadlockEscape }
  BG_SOURCE_OPAQUE_AST_NODES = Annotator::Phases::TypeAnalysisSession::BG_SOURCE_OPAQUE_AST_NODES
  SYNC_DOES_NOT_BIND_CAPTURE = Annotator::Phases::TypeAnalysisSession::SYNC_DOES_NOT_BIND_CAPTURE
  STORAGE_OUTLIVES_DECLARING_SCOPE = Annotator::Phases::TypeAnalysisSession::STORAGE_OUTLIVES_DECLARING_SCOPE
end
