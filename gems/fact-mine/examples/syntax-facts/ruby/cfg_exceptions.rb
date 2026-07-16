class CfgExceptions
  def rescue_fallback(user)
    begin
      publish(user)
    rescue StandardError
      recover(user)
    end
    finish(user)
  end

  def ensure_return(user)
    begin
      return user
    ensure
      close(user)
    end
    unreachable(user)
  end

  def rescue_ensure(user)
    begin
      publish(user)
    rescue StandardError
      recover(user)
    ensure
      close(user)
    end
    finish(user)
  end
end
