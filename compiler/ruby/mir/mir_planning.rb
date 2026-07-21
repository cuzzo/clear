# typed: strict
# frozen_string_literal: true

require "set"
require "sorbet-runtime"

require_relative "../annotator/phases/body_analysis"
require_relative "../semantic/bg_capture_classifier"
require_relative "../semantic/escape_analysis"
require_relative "cleanup_classifier"
require_relative "control_flow"

# One authoritative result for the whole-program analyses that must precede
# MIR materialization. This is deliberately not described as function-local:
# escape, BG-capture, and loop-frame analysis still consume and update the
# complete function table.
class MIRPlanningResult < T::Struct
  extend T::Sig

  CleanupPlans = T.type_alias do
    T::Hash[String, CleanupClassifier::CleanupClassificationPlan]
  end

  const :cleanup_plans, CleanupPlans
  const :escape_placements, EscapeAnalysis::EscapePlacementFacts
  const :can_fail_functions, T::Set[String]

  sig { params(name: String).returns(CleanupClassifier::CleanupClassificationPlan) }
  def cleanup_plan_for(name)
    cleanup_plans.fetch(name)
  end
end

# Establishes the global placement, capture, cleanup, loop-frame, and
# fallibility facts consumed during MIR materialization. It owns their required
# ordering so callers cannot observe a partially prepared program.
class MIRPlanner
  extend T::Sig

  FnNodes = T.type_alias { T::Hash[String, AST::FunctionDef] }
  BodySummaries = T.type_alias { T::Hash[String, Annotator::Phases::FunctionBodySummary] }
  HoistBindings = T.type_alias { T::Hash[String, T::Array[AST::VarDecl]] }

  sig do
    params(
      fn_nodes: FnNodes,
      schema_lookup: Type::SchemaLookup,
      lifecycle_registry: T.nilable(Semantic::LifecycleRegistry),
      body_summaries: BodySummaries,
      hoist_bindings: HoistBindings,
    ).returns(MIRPlanningResult)
  end
  def self.plan_all!(fn_nodes:, schema_lookup:, lifecycle_registry:, body_summaries:, hoist_bindings:)
    escape_result = EscapeAnalysis.apply_with_facts!(fn_nodes, schema_lookup, body_summaries, hoist_bindings)
    BgCaptureClassifier.classify_all!(fn_nodes, schema_lookup: schema_lookup)

    cleanup_plans = T.let({}, MIRPlanningResult::CleanupPlans)
    fn_nodes.each do |name, function|
      cleanup_plans[name] = CleanupClassifier.classify_plan(
        function,
        schema_lookup: schema_lookup,
        lifecycle_registry: lifecycle_registry,
      )
    end
    LoopFrameAnalysis.analyze!(fn_nodes, schema_lookup)

    fallible = fn_nodes.each_with_object(Set.new) do |(name, function), names|
      names << name if function.can_fail
    end.freeze

    MIRPlanningResult.new(
      cleanup_plans: cleanup_plans.freeze,
      escape_placements: escape_result.placements,
      can_fail_functions: fallible,
    ).freeze
  end
end
