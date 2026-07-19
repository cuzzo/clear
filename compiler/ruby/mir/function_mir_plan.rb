# typed: strict
# frozen_string_literal: true

require "set"
require "sorbet-runtime"

require_relative "../annotator/phases/body_analysis"
require_relative "../semantic/bg_capture_classifier"
require_relative "../semantic/escape_analysis"
require_relative "cleanup_classifier"
require_relative "control_flow"

# The complete function-local input consumed by ownership materialization.
# MIRPass owns a single map of these plans instead of parallel cleanup maps and
# late reconstruction fallbacks.
class FunctionMIRPlan < T::Struct
  extend T::Sig

  const :function, AST::FunctionDef
  const :cleanup_plan, CleanupClassifier::CleanupClassificationPlan
  const :escape_placements, T::Array[EscapeAnalysis::EscapePlacementFact]
  const :can_fail_functions, T::Set[String]

  sig { returns(CleanupClassifier::FrozenCleanupFacts) }
  def cleanup_facts
    cleanup_plan.facts
  end

  sig { returns(T::Boolean) }
  def cleanup?
    !cleanup_plan.empty?
  end
end

class FunctionMIRPlanningResult < T::Struct
  PlanMap = T.type_alias { T::Hash[String, FunctionMIRPlan] }

  const :plans, PlanMap
  const :escape_placements, EscapeAnalysis::EscapePlacementFacts
end

# Runs the analyses which establish function-local MIR contracts. Analyses that
# currently need the complete function table remain inside this coordinator;
# callers receive one authoritative plan per function and cannot observe or
# mutate partially populated cleanup state.
class FunctionMIRPlanner
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
    ).returns(FunctionMIRPlanningResult)
  end
  def self.plan_all!(fn_nodes:, schema_lookup:, lifecycle_registry:, body_summaries:, hoist_bindings:)
    escape_result = EscapeAnalysis.apply_with_facts!(fn_nodes, schema_lookup, body_summaries, hoist_bindings)
    BgCaptureClassifier.classify_all!(fn_nodes, schema_lookup: schema_lookup)

    cleanup_plans = T.let({}, T::Hash[String, CleanupClassifier::CleanupClassificationPlan])
    fn_nodes.each do |name, function|
      cleanup_plans[name] = CleanupClassifier.classify_plan(
        function,
        schema_lookup: schema_lookup,
        lifecycle_registry: lifecycle_registry,
      )
    end
    LoopFrameAnalysis.analyze!(fn_nodes, schema_lookup, lifecycle_registry)

    fallible = fn_nodes.each_with_object(Set.new) do |(name, function), names|
      names << name if function.can_fail
    end.freeze
    placements_by_function = escape_result.placements.placements.group_by(&:fn_name)
    plans = T.let({}, FunctionMIRPlanningResult::PlanMap)
    fn_nodes.each do |name, function|
      plans[name] = FunctionMIRPlan.new(
        function: function,
        cleanup_plan: cleanup_plans.fetch(name),
        escape_placements: (placements_by_function[name] || []).freeze,
        can_fail_functions: fallible,
      ).freeze
    end

    FunctionMIRPlanningResult.new(
      plans: plans.freeze,
      escape_placements: escape_result.placements,
    ).freeze
  end
end
