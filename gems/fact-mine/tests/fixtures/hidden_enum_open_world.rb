class Workflow
  def load(input)
    @state = "draft"
    @state = input
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
