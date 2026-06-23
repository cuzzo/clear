# frozen_string_literal: true

class SourceFactProtocolsNilClone
  def open
    @opened = true
  end

  def close
    @opened = false
  end

  def run(item)
    open
    close if item.ready?
  end

  def guard(value)
    return unless value

    value&.name
  end

  def guard_eq_nil(value)
    if value == nil
      return
    end
    value.name
  end

  def guard_ne_nil(value)
    if value != nil
      value.name
    end
  end

  def guard_negated(value)
    if !value
      return
    end
    value.name
  end

  def guard_both_terminate(value)
    if value.nil?
      raise "nil!"
    else
      raise "not nil!"
    end
  end

  def guard_else_terminate(value)
    if !value.nil?
      value.name
    else
      raise "nil!"
    end
  end

  def guard_safe_nav_cond(value)
    if value&.name
      value.name
    end
  end

  def clone_left(user)
    data = user.profile.name
    audit(data)
    data
  end

  def clone_right(account)
    data = account.profile.name
    audit(data)
    data
  end
end
