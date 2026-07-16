# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"
require "set"

require_relative "annotation_products"

module Annotator
  module Phases
    # A source-located inventory of the type facts required at the boundary
    # between body analysis and whole-program capability auditing.
    class AnnotationTypeInventory
      extend T::Sig

      class Violation < T::Struct
        const :class_name, String
        const :location, String
        const :type_name, String
      end

      sig { returns(Integer) }
      attr_reader :typed_node_count
      sig { returns(T::Array[Violation]) }
      attr_reader :violations

      sig { params(typed_node_count: Integer, violations: T::Array[Violation]).void }
      def initialize(typed_node_count:, violations:)
        @typed_node_count = T.let(typed_node_count, Integer)
        @violations = T.let(violations.dup.freeze, T::Array[Violation])
        freeze
      end

      sig { returns(Integer) }
      def unresolved_node_count
        violations.length
      end

      sig { void }
      def verify_resolved!
        return if violations.empty?

        sample = violations.first(20).map do |violation|
          "  - #{violation.class_name} @ #{violation.location}: #{violation.type_name}"
        end.join("\n")
        more = violations.length > 20 ? "\n  ... (+#{violations.length - 20} more)" : ""
        raise "annotation boundary has unresolved AST type facts:\n#{sample}#{more}"
      end

      sig { params(program: AST::Program).returns(AnnotationTypeInventory) }
      def self.scan(program)
        ignored_node_ids = ignored_node_ids(program)
        typed_node_count = 0
        violations = T.let([], T::Array[Violation])

        AST.each_locatable(program, descend_functions: true) do |node|
          next if ignored_node_ids.include?(node.object_id)

          node_type = node_type(node)
          if node_type.untyped? || node_type.auto?
            violations << Violation.new(
              class_name: class_name(node),
              location: location(node),
              type_name: node_type.to_s
            )
          else
            typed_node_count += 1
          end
        end

        new(typed_node_count: typed_node_count, violations: violations)
      end

      sig { params(program: AST::Program).returns(T::Set[Integer]) }
      def self.ignored_node_ids(program)
        ignored = T.let(Set.new, T::Set[Integer])
        program.statements.each do |statement|
          next unless statement.is_a?(AST::FunctionDef)

          add_lifetime_metadata_node_ids!(ignored, statement.return_lifetime)
        end
        ignored
      end
      private_class_method :ignored_node_ids

      LifetimeMetadata = T.type_alias do
        T.nilable(T.any(Symbol, AST::Locatable, T::Array[T.any(Symbol, AST::Locatable)]))
      end

      sig { params(ignored: T::Set[Integer], value: LifetimeMetadata).void }
      def self.add_lifetime_metadata_node_ids!(ignored, value)
        case value
        when AST::Locatable
          AST.each_locatable(value, descend_functions: true) { |node| ignored.add(node.object_id) }
        when Array
          value.each { |entry| add_lifetime_metadata_node_ids!(ignored, entry) }
        end
      end
      private_class_method :add_lifetime_metadata_node_ids!

      sig { params(node: AST::Locatable).returns(Type) }
      def self.node_type(node)
        return Type.new(:Untyped) unless node.typed?

        node.full_type!(context: "annotation type inventory")
      end
      private_class_method :node_type

      sig { params(node: AST::Locatable).returns(String) }
      def self.class_name(node)
        (node.class.name || node.class.to_s).split("::").last || node.class.to_s
      end
      private_class_method :class_name

      sig { params(node: AST::Locatable).returns(String) }
      def self.location(node)
        token = node.token
        return "?" unless token

        "#{token.line}:#{token.column}"
      end
      private_class_method :location
    end

    class TypeAnalysisPhase
      extend T::Sig

      sig do
        params(
          resolution: ResolutionFacts,
          session: TypeAnalysisSession
        ).returns(TypeAnalysisHandoff)
      end
      def self.run(resolution:, session:)
        session.execute_type_analysis!(resolution)
      end
    end
  end
end
