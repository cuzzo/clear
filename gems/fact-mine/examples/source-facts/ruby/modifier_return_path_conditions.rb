# frozen_string_literal: true

class SourceFactModifierReturnPathConditions
  def load(path)
    return empty unless path && ::File.file?(path)

    parse(path)
  end

  def risk_multiplier(tests, types, killed)
    return 0.55 if killed >= 3
    return 0.80 if tests >= 5 && types >= 2

    0.98
  end
end
