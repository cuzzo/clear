# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "../../ast/ast"
require_relative "../../semantic/pass_state"
require_relative "../helpers/function_signature"
require_relative "annotation_products"
require_relative "type_analysis_phase"

module Annotator
  module Phases
    # Fail-closed boundary between annotation and MIR. It verifies only
    # published immutable products and therefore cannot depend on executor
    # lifecycle state that has already been relinquished.
    module AnnotationBoundary
      extend T::Sig

      sig { params(program: AST::Program, products: AnnotationProducts).void }
      def self.verify!(program, products)
        typed_program = products.typed_program
        raise "annotation boundary requires typed program facts" unless typed_program
        raise "annotation boundary received a different program" unless typed_program.program.equal?(program)

        program.full_type!(context: "annotation boundary program")
        AnnotationTypeInventory.scan(program).verify_resolved!
        typed_program.resolution.function_registry.nodes.each do |name, fn|
          signature = FunctionSignature.unwrap(fn.full_type!(context: "annotation boundary function #{name}"))
          raise "annotation boundary missing function signature for #{name}" unless signature
          derived = products.capability_audit&.derived_program&.functions&.fetch(name, nil)
          raise "annotation boundary missing derived function facts for #{name}" unless derived
          unless derived.return_type_key == signature.return_type.semantic_type_key
            raise "annotation boundary derived return contract mismatch for #{name}"
          end
        end
        MIRPassState.for!(program).mark!(:annotated)
      end
    end
  end
end
