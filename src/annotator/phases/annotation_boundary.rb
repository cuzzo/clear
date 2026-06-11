# typed: strict
require "sorbet-runtime"
require "set"

require_relative "../../ast/ast"
require_relative "../../semantic/pass_state"

module Annotator
  module Phases
    module AnnotationBoundary
      extend T::Sig

      class BoundaryTypeViolation < T::Struct
        const :class_name, String
        const :location, String
        const :type_name, String
      end

      sig { params(program: AST::Program).void }
      def mark_annotation_complete!(program)
        T.bind(self, SemanticAnnotator)

        verify_annotation_boundary!(program)
        MIRPassState.for!(program).mark!(:annotated)
      end

      sig { params(program: AST::Program).void }
      def verify_annotation_boundary!(program)
        T.bind(self, SemanticAnnotator)

        program.full_type!(context: "annotation boundary program")
        violations = annotation_type_violations(program)
        unless violations.empty?
          sample = violations.first(20).map do |violation|
            "  - #{violation.class_name} @ #{violation.location}: #{violation.type_name}"
          end.join("\n")
          more = violations.length > 20 ? "\n  ... (+#{violations.length - 20} more)" : ""
          raise "annotation boundary has unresolved AST type facts:\n#{sample}#{more}"
        end

        unless pending_deferred_validation_count.zero?
          raise "annotation boundary has pending deferred validations"
        end

        semantic_function_nodes.each do |name, fn|
          signature = FunctionSignature.unwrap(fn.full_type!(context: "annotation boundary function #{name}"))
          raise "annotation boundary missing function signature for #{name}" unless signature
        end
      end
      private :verify_annotation_boundary!

      sig { params(program: AST::Program).returns(T::Array[BoundaryTypeViolation]) }
      def annotation_type_violations(program)
        violations = T.let([], T::Array[BoundaryTypeViolation])
        ignored_node_ids = annotation_boundary_ignored_node_ids(program)
        AST.each_locatable(program, descend_functions: true) do |node|
          next if ignored_node_ids.include?(node.object_id)
          node_type = annotation_boundary_node_type(node)
          next unless node_type.untyped? || node_type.auto?
          violations << BoundaryTypeViolation.new(
            class_name: annotation_boundary_class_name(node),
            location: annotation_boundary_location(node),
            type_name: node_type.to_s
          )
        end
        violations
      end
      private :annotation_type_violations

      sig { params(program: AST::Program).returns(T::Set[Integer]) }
      def annotation_boundary_ignored_node_ids(program)
        ignored = T.let(Set.new, T::Set[Integer])
        program.statements.each do |statement|
          next unless statement.is_a?(AST::FunctionDef)

          add_lifetime_metadata_node_ids!(ignored, statement.return_lifetime)
        end
        ignored
      end
      private :annotation_boundary_ignored_node_ids

      LifetimeMetadata = T.type_alias do
        T.nilable(T.any(Symbol, AST::Locatable, T::Array[T.any(Symbol, AST::Locatable)]))
      end

      sig { params(ignored: T::Set[Integer], value: LifetimeMetadata).void }
      def add_lifetime_metadata_node_ids!(ignored, value)
        case value
        when AST::Locatable
          AST.each_locatable(value, descend_functions: true) do |node|
            ignored.add(node.object_id)
          end
        when Array
          value.each { |entry| add_lifetime_metadata_node_ids!(ignored, entry) }
        end
      end
      private :add_lifetime_metadata_node_ids!

      sig { params(node: AST::Locatable).returns(Type) }
      def annotation_boundary_node_type(node)
        return Type.new(:Untyped) unless node.typed?

        node.full_type!(context: "annotation boundary node")
      end
      private :annotation_boundary_node_type

      sig { params(node: AST::Locatable).returns(String) }
      def annotation_boundary_class_name(node)
        (node.class.name || node.class.to_s).split("::").last || node.class.to_s
      end
      private :annotation_boundary_class_name

      sig { params(node: AST::Locatable).returns(String) }
      def annotation_boundary_location(node)
        token = node.token
        return "?" unless token
        "#{token.line}:#{token.column}"
      end
      private :annotation_boundary_location
    end
  end
end
