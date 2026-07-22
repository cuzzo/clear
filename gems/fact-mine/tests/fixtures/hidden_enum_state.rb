class Workflow
  def initialize
    @state = "draft"
  end

  def draft!
    @state = "draft"
  end

  def ready?
    @state == "draft"
  end

  def complete?
    @state == "complete"
  end

  def allowed?(state)
    state == "draft" || "complete" == state
  end

  def listed?(state)
    ["draft", "complete"].include?(state)
  end

  def dispatch
    case @state
    when "draft"
      true
    when "complete"
      false
    end
  end
end
