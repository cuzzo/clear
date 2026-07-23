class NullableRuby
  def guarded_disjunction(flag)
    value = nil
    if value === nil || flag == 5
      0
    else
      value.length
    end
  end
end
