class CfgMetrics
  def linear(user)
    audit(user)
    finish(user)
  end

  def branch(user)
    if user.ready?
      publish(user)
    else
      warn(user)
    end
    finish(user)
  end

  def loop_case(items, role)
    items.each do |item|
      case role
      when :owner
        publish(item)
      else
        warn(item)
      end
    end
    finish(items)
  end

  def exception_flow(user)
    begin
      publish(user)
    rescue StandardError
      recover(user)
    ensure
      close(user)
    end
    finish(user)
  end

  def exception_callback(user)
    transaction do
      begin
        publish(user)
      rescue StandardError
        recover(user)
      ensure
        close(user)
      end
    end
    finish(user)
  end

  def terminal(user)
    return unless user.ready?
    publish(user)
  end
end
