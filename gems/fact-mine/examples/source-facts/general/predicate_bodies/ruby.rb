# frozen_string_literal: true

class SourceFactPredicateBodies
  def simple_predicate?(value)
    value == false
  end

  def trailing_false_is_not_body?(value)
    return true if value.nil?
    return true if value == :known

    false
  end
end
