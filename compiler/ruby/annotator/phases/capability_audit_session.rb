# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "../../ast/fixable_error"
require_relative "../../ast/scope"
require_relative "../../ast/source_error"
require_relative "../function_registry"
require_relative "../helpers/capabilities"
require_relative "../helpers/effects"
require_relative "../helpers/fixable_helpers"
require_relative "../helpers/lock_helper"
require_relative "../helpers/reentrance"
require_relative "annotation_products"
require_relative "capability_evidence"
require_relative "deferred_validation"
require_relative "program_finalization"
require_relative "whole_program_semantics"

module Annotator
  module Phases
    # Sequential owner for whole-program capability auditing. It receives the
    # immutable facts relinquished by type analysis and owns no typing state.
    class CapabilityAuditSession
      extend T::Sig

      class Context < T::Struct
        const :typed_program, TypedProgramFacts
        const :inputs, CapabilityAuditInputs
        const :source_code, T.nilable(String)
        const :language_mode, Symbol
        const :strict_test, T::Boolean
      end

      include ErrorHelper
      include FixableHelper
      include ScopeHelper
      include EffectAudit
      include EffectQueries
      include ReentranceAudit
      include ReentranceQueries
      include PredicateAudit
      include CapabilityUsageAudit
      include LockAudit
      include DeferredCapabilityAudit
      include ProgramCapabilityAudit
      include WholeProgramSemantics

      sig do
        params(
          typed_program: TypedProgramFacts,
          inputs: CapabilityAuditInputs,
          source_code: T.nilable(String),
          language_mode: Symbol,
          strict_test: T::Boolean
        ).void
      end
      def initialize(typed_program:, inputs:, source_code:, language_mode:, strict_test:)
        @context = T.let(Context.new(
          typed_program: typed_program,
          inputs: inputs,
          source_code: source_code,
          language_mode: language_mode,
          strict_test: strict_test
        ), Context)
      end

      sig { void }
      def audit!
        finalize_program_audit!(semantic_program)
        run_whole_program_semantics!
        run_deferred_validations!
      end

      private

      sig { returns(CapabilityAuditInputs) }
      def phase_audit_inputs = @context.inputs

      sig { returns(T::Hash[String, AST::FunctionDef]) }
      def semantic_function_nodes = semantic_function_registry.nodes

      alias_method :function_node_map, :semantic_function_nodes

      sig { params(name: T.nilable(String)).returns(T.nilable(AST::FunctionDef)) }
      def function_node_for(name) = semantic_function_registry.fetch(name)

      sig { returns(Scope) }
      def semantic_root_scope = @context.typed_program.resolution.root_scope

      sig { returns(AST::Program) }
      def semantic_program = @context.typed_program.program

      sig { returns(T::Hash[Symbol, Integer]) }
      def semantic_lock_type_ranks = phase_audit_inputs.lock_analysis.type_ranks

      sig { override.returns(T::Array[Scope]) }
      def scope_stack = [semantic_root_scope]

      sig { returns(T::Hash[String, FunctionBodySummary]) }
      def function_body_summaries = @context.typed_program.body_summaries

      sig { returns(T::Hash[String, T::Set[String]]) }
      def function_call_graph = semantic_function_registry.call_graph

      sig { returns(T::Hash[String, T::Set[String]]) }
      def function_propagating_callees = semantic_function_registry.propagating_callees

      sig { params(name: String).returns(T::Boolean) }
      def function_has_fnptr_call?(name) = semantic_function_registry.fnptr_call?(name)

      sig { params(name: String).returns(T::Boolean) }
      def function_raises_directly?(name) = semantic_function_registry.raises_directly?(name)

      sig { params(node: AST::FunctionDef).returns(T::Boolean) }
      def function_has_pre_clauses?(node) = node.pre_clauses.is_a?(Array) && node.pre_clauses.any?

      sig { params(node: AST::FunctionDef).returns(T::Boolean) }
      def function_has_catch_clauses?(node) = node.catch_clauses.is_a?(Array) && node.catch_clauses.any?

      sig { params(node: AST::FunctionDef).returns(T::Boolean) }
      def function_has_default_catch?(node) = node.default_catch.is_a?(Array) && node.default_catch.any?

      sig { returns(T::Array[DeferredWithValidation]) }
      def deferred_with_validations = phase_audit_inputs.deferred_with_validations

      sig { returns(T::Array[DeferredRecoveryValidation]) }
      def deferred_recovery_validations = phase_audit_inputs.deferred_recovery_validations

      sig { returns(CapabilityAudit::BindingAuditStore) }
      def capability_audit = phase_audit_inputs.capability_audit

      sig { returns(T::Array[CapabilityHelper::PredicateCallSite]) }
      def predicate_call_sites = phase_audit_inputs.predicate_call_sites

      sig { returns(T::Array[AsyncBodyFact]) }
      def async_body_facts = phase_audit_inputs.async_body_facts

      sig { returns(Symbol) }
      def language_mode = @context.language_mode

      sig { override.returns(T.nilable(String)) }
      def source_code = @context.source_code

      sig { returns(T::Boolean) }
      def strict_test? = @context.strict_test

      sig { returns(Annotator::FunctionRegistry) }
      def semantic_function_registry = @context.typed_program.resolution.function_registry

      # Audit/query modules are implementation protocols of this executor.
      # The completed audit is the only externally ordered operation.
      private(*T.unsafe(public_instance_methods - Object.public_instance_methods - [:audit!]))
    end
  end
end
