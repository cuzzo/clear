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
