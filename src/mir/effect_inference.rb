# frozen_string_literal: true

require_relative "effect_set"

# Phase 3.2: project the closed effect lattice from existing annotator
# fields. Direct effects are recorded by the annotator at visit_X sites
# (record_effect(EffectTracker::YIELD) etc.); compute_effects! propagates
# transitively over @call_graph; fn.can_fail is computed by the existing
# can-fail post-pass. EffectInference adds nothing at runtime — it just
# packages those facts as an EffectSet for the formatter and concurrency
# checks.
module EffectInference
  module_function

  # After the annotator's compute_effects! has stamped fn.effects, fold
  # those into a closed-lattice EffectSet on each FunctionDef.
  def analyze!(fn_nodes)
    fn_nodes.each do |_name, fn|
      next unless fn
      fn.effect_set = build(fn)
      fn.inferred_effects = fn.effect_set
    end
  end

  # Project a single function's closed-lattice effects from the
  # annotator-stamped fields. Pure read; no walking.
  def build(fn)
    eff = Set.new
    raw = fn.respond_to?(:effects) ? fn.effects : nil

    eff << :yield      if raw&.include?(EffectTracker::YIELD)
    eff << :alloc_heap if raw&.include?(EffectTracker::HEAP)
    eff << :io         if raw&.include?(EffectTracker::IO) ||
                          raw&.include?(EffectTracker::EXTERN)
    eff << :fail       if fn.respond_to?(:can_fail) && fn.can_fail

    # Atomics M1.6.5: project the contention / blocking axis. Concrete
    # effects from atomic / versioned / locked use sites; ?-form when
    # the binding's REQUIRES is polymorphic across lock-free /
    # lock-based families.
    eff << :contention  if raw&.include?(EffectTracker::CONTENTION)
    eff << :blocking    if raw&.include?(EffectTracker::BLOCKING)
    eff << :"contention?" if raw&.include?(EffectTracker::CONTENTION_MAYBE)
    eff << :"blocking?"   if raw&.include?(EffectTracker::BLOCKING_MAYBE)

    EffectSet.new(eff)
  end
end
