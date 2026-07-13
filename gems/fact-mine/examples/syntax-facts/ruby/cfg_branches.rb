class CfgBranches
  def simple_if(user)
    prepare(user)
    if user.ready?
      publish(user)
    else
      warn(user)
    end
    finish(user)
  end

  def missing_else(user)
    if user.ready?
      publish(user)
    end
    finish(user)
  end

  def nested_branch(user)
    if user.ready?
      if user.allowed?
        publish(user)
      end
    else
      warn(user)
    end
    finish(user)
  end

  def boolean_short_circuit(user)
    if user.ready? && user.allowed?
      publish(user)
    end
    finish(user)
  end
end
