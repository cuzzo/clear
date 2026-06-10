# typed: strict
require "sorbet-runtime"

require_relative "../../ast/ast"
require_relative "../helpers/function_signature"

module Annotator
  module Phases
    module ProgramFinalization
      extend T::Sig

      sig { params(program: AST::Program).void }
      def finalize_program_semantics!(program)
        T.bind(self, SemanticAnnotator)

        check_indirect_reentrancy!
        validate_not_logical_recursion!
        validate_max_depth_mutual_cycle!
        validate_thunk_recursion!

        compute_needs_rt!
        compute_can_fail!
        enforce_fallible_returns!
        mark_fn_value_references!(program)

        compute_effects!
        validate_predicate_purity!

        compute_fsm_eligibility!
        enumerate_fsm_suspend_points!

        check_lock_cycles!
        compute_stack_tiers!
        finalize_async_execution_shapes!(program)

        restamp_function_metadata!
        stamp_program_result_type!(program)
      end

      sig { void }
      def restamp_function_metadata!
        T.bind(self, SemanticAnnotator)

        semantic_function_nodes.each_value do |fn|
          signature = FunctionSignature.unwrap(fn.full_type!(context: "program function signature"))
          next unless signature

          signature.can_fail = fn.can_fail
          signature.effects = fn.effects
          signature.stack_tier = fn.stack_tier
        end
      end
      private :restamp_function_metadata!

      sig { params(program: AST::Program).void }
      def stamp_program_result_type!(program)
        T.bind(self, SemanticAnnotator)

        final_statement = program.statements.last
        if final_statement
          stamp_type!(program, final_statement.full_type!(context: "program final statement"))
        else
          stamp_type!(program, :Void)
        end
      end
      private :stamp_program_result_type!
    end
  end
end
