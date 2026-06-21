# frozen_string_literal: true

class SourceFactNormalizedBooleanComplexity
  def eligible?(user, cart)
    if user.active? && !user.suspended?
      cart.total > 0 || cart.free?
    end
  end
end
