# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "annotation_products"

module Annotator
  module Phases
    # The intentionally narrow compatibility surface used while registration
    # algorithms move out of SemanticAnnotator. ResolutionPhase owns ordering;
    # callers can provide only the six operations that belong to resolution.
    class ResolutionOperations
      extend T::Sig

      ImportResolver = T.type_alias { T.proc.params(node: AST::RequireNode).void }
      DeclarationAction = T.type_alias { T.proc.params(declarations: DeclarationIndex).void }
      ProgramAction = T.type_alias { T.proc.params(program: AST::Program).void }

      sig { returns(ImportResolver) }
      attr_reader :resolve_import
      sig { returns(DeclarationAction) }
      attr_reader :register_types, :register_signatures, :seed_error_types
      sig { returns(ProgramAction) }
      attr_reader :resolve_reentrance, :resolve_sync_policy

      sig do
        params(
          resolve_import: ImportResolver,
          register_types: DeclarationAction,
          register_signatures: DeclarationAction,
          resolve_reentrance: ProgramAction,
          resolve_sync_policy: ProgramAction,
          seed_error_types: DeclarationAction
        ).void
      end
      def initialize(resolve_import:, register_types:, register_signatures:, resolve_reentrance:, resolve_sync_policy:, seed_error_types:)
        @resolve_import = resolve_import
        @register_types = register_types
        @register_signatures = register_signatures
        @resolve_reentrance = resolve_reentrance
        @resolve_sync_policy = resolve_sync_policy
        @seed_error_types = seed_error_types
        freeze
      end
    end

    class ResolutionPhase
      extend T::Sig

      sig do
        params(
          program: AST::Program,
          root_scope: Scope,
          function_registry: Annotator::FunctionRegistry,
          operations: ResolutionOperations
        ).returns(ResolutionFacts)
      end
      def self.run(program:, root_scope:, function_registry:, operations:)
        declarations = DeclarationIndexer.index(program)

        declarations.imports.each { |node| operations.resolve_import.call(node) }
        operations.register_types.call(declarations)
        operations.register_signatures.call(declarations)
        operations.resolve_reentrance.call(program)
        operations.resolve_sync_policy.call(program)
        operations.seed_error_types.call(declarations)

        ResolutionFacts.new(
          program: program,
          declarations: declarations,
          root_scope: root_scope,
          function_registry: function_registry,
          type_names: root_scope.types.keys,
          function_names: resolved_function_names(root_scope)
        )
      end

      sig { params(root_scope: Scope).returns(T::Array[String]) }
      def self.resolved_function_names(root_scope)
        root_scope.visible_entries.each_with_object(T.let([], T::Array[String])) do |(name, entry), names|
          names << name if entry.fn_signature
        end
      end
      private_class_method :resolved_function_names
    end
  end
end
