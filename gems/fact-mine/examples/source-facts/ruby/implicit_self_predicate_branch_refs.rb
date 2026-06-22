# frozen_string_literal: true

class SourceFactImplicitSelfPredicateBranchRefs
  def branch_refs(mod, fn, calls)
    return false unless states(mod).empty?
    return false if state_touch_count(fn).positive?
    return false unless calls.empty? && internal_calls_for(fn).empty?

    true
  end
end
