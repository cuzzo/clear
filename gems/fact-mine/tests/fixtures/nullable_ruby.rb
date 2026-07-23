class NullableRuby
  def guarded_disjunction(flag)
    value = nil
    if value === nil || flag == 5
      0
    else
      value.length
    end
  end

  # The then edge proves non-nil only inside the condition body. The implicit
  # false edge joins at the final call with the original nil assignment.
  def refinement_must_not_survive_join(flag)
    value = nil
    if value != nil && flag
      value.length
    end
    value.length
  end
end
