class CfgReturns
  def early_return(user)
    return user
    unreachable(user)
  end

  def branch_return(user)
    if user.ready?
      return user
    end
    publish(user)
  end

  def loop_return(items)
    items.each do |item|
      if item.done?
        return item
      end
      publish(item)
    end
    finish(items)
  end

  def tail_return(user)
    publish(user)
    return user
  end
end
