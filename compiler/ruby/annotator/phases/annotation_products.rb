# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "../../ast/ast"
require_relative "../../ast/scope"
require_relative "../../semantic/ownership_graph"
require_relative "../../semantic/lifecycle_plan"
require_relative "../function_registry"
require_relative "body_analysis"
require_relative "conformance_registration"
require_relative "declaration_index"
require_relative "implementation_registration"
require_relative "derived_program_facts"

module Annotator
  module Phases
    # Immutable product of declaration/import/name/contract resolution.
    # Scope and FunctionRegistry remain compatibility references during the
    # migration, while the product-owned indexes are frozen snapshots.
    class ResolutionFacts
      extend T::Sig

      sig { returns(ResolutionFacts) }
      def self.empty
        program = AST::Program.new(nil, [])
        root_scope = Scope.new
        function_registry = Annotator::FunctionRegistry.new
        new(
          program: program,
          declarations: DeclarationIndexer.index(program),
          root_scope: root_scope,
          function_registry: function_registry,
          implementation_resolutions: [],
          conformance_resolutions: [],
          protocols: {},
          type_names: root_scope.types.keys,
          function_names: function_registry.names
        )
      end

      sig { returns(AST::Program) }
      attr_reader :program
      sig { returns(DeclarationIndex) }
      attr_reader :declarations
      sig { returns(Scope) }
      attr_reader :root_scope
      sig { returns(Annotator::FunctionRegistry) }
      attr_reader :function_registry
      sig { returns(T::Array[ImplementationResolution]) }
      attr_reader :implementation_resolutions
      sig { returns(T::Array[ConformanceResolution]) }
      attr_reader :conformance_resolutions
      sig { returns(T::Hash[String, AST::ProtocolDef]) }
      attr_reader :protocols
      sig { returns(T::Array[Symbol]) }
      attr_reader :type_names
      sig { returns(T::Array[String]) }
      attr_reader :function_names
      sig do
        params(
          program: AST::Program,
          declarations: DeclarationIndex,
          root_scope: Scope,
          function_registry: Annotator::FunctionRegistry,
          type_names: T::Array[Symbol],
          function_names: T::Array[String],
          implementation_resolutions: T::Array[ImplementationResolution],
          conformance_resolutions: T::Array[ConformanceResolution],
          protocols: T::Hash[String, AST::ProtocolDef]
        ).void
      end
      def initialize(program:, declarations:, root_scope:, function_registry:, type_names:, function_names:, implementation_resolutions: [], conformance_resolutions: [], protocols: {})
        @program = T.let(program, AST::Program)
        @declarations = T.let(declarations, DeclarationIndex)
        @root_scope = T.let(root_scope, Scope)
        @function_registry = T.let(function_registry, Annotator::FunctionRegistry)
        @implementation_resolutions = T.let(implementation_resolutions.dup.freeze, T::Array[ImplementationResolution])
        @conformance_resolutions = T.let(conformance_resolutions.dup.freeze, T::Array[ConformanceResolution])
        @protocols = T.let(protocols.dup.freeze, T::Hash[String, AST::ProtocolDef])
        @type_names = T.let(type_names.dup.freeze, T::Array[Symbol])
        @function_names = T.let(function_names.dup.freeze, T::Array[String])
        freeze
      end
    end

    # Immutable publication boundary for body typing and type finalization.
    class TypedProgramFacts
      extend T::Sig

      BodySummaries = T.type_alias { T::Hash[String, FunctionBodySummary] }
      LocalFacts = T.type_alias { T::Hash[String, LocalFunctionFacts] }

      sig { returns(ResolutionFacts) }
      attr_reader :resolution
      sig { returns(BodySummaries) }
      attr_reader :body_summaries
      sig { returns(LocalFacts) }
      attr_reader :local_function_facts
      sig { returns(Integer) }
      attr_reader :typed_node_count
      sig { returns(Integer) }
      attr_reader :unresolved_node_count
      sig { returns(OwnershipGraph) }
      attr_reader :ownership_graph
      sig { returns(Semantic::LifecycleRegistry) }
      attr_reader :lifecycle_registry

      sig do
        params(
          resolution: ResolutionFacts,
          body_summaries: BodySummaries,
          typed_node_count: Integer,
          unresolved_node_count: Integer,
          ownership_graph: OwnershipGraph,
          lifecycle_registry: Semantic::LifecycleRegistry,
          local_function_facts: T.nilable(LocalFacts)
        ).void
      end
      def initialize(resolution:, body_summaries:, typed_node_count:, unresolved_node_count:, ownership_graph:, lifecycle_registry: Semantic::LifecycleRegistry.empty, local_function_facts: nil)
        raise "typed program cannot publish unresolved nodes" unless unresolved_node_count.zero?

        @resolution = T.let(resolution, ResolutionFacts)
        @body_summaries = T.let(body_summaries.dup.freeze, BodySummaries)
        facts = local_function_facts || body_summaries.transform_values { |summary| LocalFunctionFacts.from_summary(summary) }
        @local_function_facts = T.let(facts.sort.to_h.freeze, LocalFacts)
        @typed_node_count = T.let(typed_node_count, Integer)
        @unresolved_node_count = T.let(unresolved_node_count, Integer)
        @ownership_graph = T.let(ownership_graph, OwnershipGraph)
        @lifecycle_registry = T.let(lifecycle_registry, Semantic::LifecycleRegistry)
        freeze
      end

      sig { returns(AST::Program) }
      def program
        resolution.program
      end
    end

    # Immutable result of capability, ownership, effect, lock, and deferred
    # semantic validation over a completely typed program.
    class CapabilityAuditReport
      extend T::Sig

      sig { returns(TypedProgramFacts) }
      attr_reader :typed_program
      sig { returns(DerivedProgramFacts) }
      attr_reader :derived_program
      sig { returns(T::Array[String]) }
      attr_reader :checked_functions
      sig { returns(Integer) }
      attr_reader :checked_call_sites, :checked_with_sites, :violation_count

      sig do
        params(
          typed_program: TypedProgramFacts,
          derived_program: DerivedProgramFacts,
          checked_functions: T::Array[String],
          checked_call_sites: Integer,
          checked_with_sites: Integer,
          violation_count: Integer
        ).void
      end
      def initialize(typed_program:, derived_program:, checked_functions:, checked_call_sites:, checked_with_sites:, violation_count:)
        @typed_program = T.let(typed_program, TypedProgramFacts)
        @derived_program = T.let(derived_program, DerivedProgramFacts)
        @checked_functions = T.let(checked_functions.dup.freeze, T::Array[String])
        @checked_call_sites = T.let(checked_call_sites, Integer)
        @checked_with_sites = T.let(checked_with_sites, Integer)
        @violation_count = T.let(violation_count, Integer)
        freeze
      end

      sig { returns(T::Boolean) }
      def success?
        violation_count.zero?
      end
    end

    # Immutable pipeline ledger with fail-closed publication order. Publishing
    # returns a new frozen snapshot, so diagnostics can retain the last complete
    # phase without exposing a partially mutated result object.
    class AnnotationProducts
      extend T::Sig

      sig { returns(T.nilable(ResolutionFacts)) }
      attr_reader :resolution
      sig { returns(T.nilable(TypedProgramFacts)) }
      attr_reader :typed_program
      sig { returns(T.nilable(CapabilityAuditReport)) }
      attr_reader :capability_audit

      sig do
        params(
          resolution: T.nilable(ResolutionFacts),
          typed_program: T.nilable(TypedProgramFacts),
          capability_audit: T.nilable(CapabilityAuditReport)
        ).void
      end
      def initialize(resolution: nil, typed_program: nil, capability_audit: nil)
        @resolution = T.let(resolution, T.nilable(ResolutionFacts))
        @typed_program = T.let(typed_program, T.nilable(TypedProgramFacts))
        @capability_audit = T.let(capability_audit, T.nilable(CapabilityAuditReport))
        freeze
      end

      sig { params(facts: ResolutionFacts).returns(AnnotationProducts) }
      def publish_resolution(facts)
        raise "resolution facts already published" if @resolution

        AnnotationProducts.new(resolution: facts)
      end

      sig { params(facts: TypedProgramFacts).returns(AnnotationProducts) }
      def publish_typed_program(facts)
        resolution = @resolution
        raise "type analysis requires resolution facts" unless resolution
        raise "type analysis used different resolution facts" unless facts.resolution.equal?(resolution)
        raise "typed program facts already published" if @typed_program

        AnnotationProducts.new(resolution: resolution, typed_program: facts)
      end

      sig { params(report: CapabilityAuditReport).returns(AnnotationProducts) }
      def publish_capability_audit(report)
        typed_program = @typed_program
        raise "capability audit requires typed program facts" unless typed_program
        raise "capability audit used different typed program facts" unless report.typed_program.equal?(typed_program)
        raise "capability audit report already published" if @capability_audit

        AnnotationProducts.new(
          resolution: T.must(@resolution),
          typed_program: typed_program,
          capability_audit: report
        )
      end

      sig { returns(T::Boolean) }
      def complete?
        !@resolution.nil? && !@typed_program.nil? && !@capability_audit.nil?
      end
    end
  end
end
