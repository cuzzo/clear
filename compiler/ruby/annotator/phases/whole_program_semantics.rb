# typed: strict
require "sorbet-runtime"

require_relative "../../ast/ast"
require_relative "../../ast/scope"
require_relative "../../semantic/bg_capture_classifier"
require_relative "../../semantic/capability_plan"
require_relative "../../semantic/concurrency_checks"
require_relative "../../semantic/effect_inference"
require_relative "../../semantic/escape_analysis"
require_relative "../helpers/function_signature"
require_relative "../helpers/with_match_check"

module Annotator
  module Phases
    module WholeProgramSemantics
      extend T::Sig

      sig { void }
      def run_whole_program_semantics!
        T.bind(self, Annotator::Phases::CapabilityAuditSession)

        # Caller sync depends on annotated call-site args, so propagate it after
        # the body walk and before replaying deferred WITH validations.
        fn_nodes = whole_program_fn_nodes
        body_summaries = function_body_summaries

        EscapeAnalysis.propagate_caller_sync!(fn_nodes, body_summaries)
        fn_nodes.each_value do |fn|
          CapabilityPlan.refresh_function_plans!(fn, body_summaries.fetch(fn.name).with_blocks)
        end

        # Single authority for BG capture-strategy facts. This runs after caller
        # sync propagation so SymbolEntry stamps are final, and before downstream
        # passes that consume BgBlock.capture_analysis.
        BgCaptureClassifier.classify_all!(fn_nodes, schema_lookup: lambda { |type|
          begin
            lookup_type_schema(type)
          rescue StandardError
            nil
          end
        })

        EffectInference.analyze!(fn_nodes)

        error_handler = lambda { |node, message|
          error!(node, :EFFECT_INFERENCE_VIOLATION, detail: message)
        }
        warning_handler = lambda { |node, message| note!(node, message) }
        root_scope = whole_program_root_scope
        signature_lookup = lambda { |name| root_scope.resolve_entry(name)&.type }
        policy_handlers = whole_program_node&.sync_policy

        fn_nodes.each_value do |fn|
          WithMatchCheck.check_function!(
            fn,
            body_summaries.fetch(fn.name).with_blocks,
            error_handler,
            warn_handler: warning_handler,
            policy_handlers: policy_handlers
          )
        end

        restamp_requires_on_signatures!
        fn_nodes.each_value do |fn|
          WithMatchCheck.check_call_sites!(
            body_summaries.fetch(fn.name).call_site_facts,
            signature_lookup,
            error_handler
          )
        end

        # Rank-annotated locks are checked by the rank-DAG analysis, not the
        # pattern-based naked-nested-WITH check.
        ConcurrencyChecks.check_all!(
          fn_nodes,
          signature_lookup,
          error_handler,
          body_summaries: body_summaries,
          lock_ranks: whole_program_lock_type_ranks
        )
      end

      sig { void }
      def restamp_requires_on_signatures!
        T.bind(self, Annotator::Phases::CapabilityAuditSession)

        root_scope = whole_program_root_scope
        whole_program_fn_nodes.each do |name, fn|
          signature = FunctionSignature.unwrap(root_scope.resolve_entry(name)&.type)
          FunctionSignature.sync_signature_from_function_def!(signature, fn) if signature
        end
      end
      private :restamp_requires_on_signatures!

      sig { returns(T::Hash[String, AST::FunctionDef]) }
      def whole_program_fn_nodes
        T.bind(self, Annotator::Phases::CapabilityAuditSession)
        semantic_function_nodes
      end
      private :whole_program_fn_nodes

      sig { returns(Scope) }
      def whole_program_root_scope
        T.bind(self, Annotator::Phases::CapabilityAuditSession)
        semantic_root_scope
      end
      private :whole_program_root_scope

      sig { returns(T.nilable(AST::Program)) }
      def whole_program_node
        T.bind(self, Annotator::Phases::CapabilityAuditSession)
        semantic_program
      end
      private :whole_program_node

      sig { returns(T::Hash[Symbol, Integer]) }
      def whole_program_lock_type_ranks
        T.bind(self, Annotator::Phases::CapabilityAuditSession)
        semantic_lock_type_ranks
      end
      private :whole_program_lock_type_ranks
    end
  end
end
