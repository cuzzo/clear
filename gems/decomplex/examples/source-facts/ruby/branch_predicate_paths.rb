# frozen_string_literal: true

class SourceFactBranchPredicatePaths
  def ready?
    @status == :ready
  end

  def route(user)
    if @status == :ready && user.active?
      publish(:ready)
    else
      warn("not ready")
    end

    case user.role
    when "admin"
      audit(user)
    when "guest"
      fallback(user)
    else
      default(user)
    end
  end
end
