class CfgLoops
  def while_loop(user)
    while user.ready?
      publish(user)
    end
    finish(user)
  end

  def until_loop(user)
    until user.ready?
      publish(user)
    end
    finish(user)
  end

  def iterator_loop(items)
    items.each do |item|
      publish(item)
    end
    finish(items)
  end

  def break_loop(items)
    items.each do |item|
      break if item.done?
      publish(item)
    end
    finish(items)
  end

  def next_loop(items)
    items.each do |item|
      next if item.skip?
      publish(item)
    end
    finish(items)
  end

  def nested_loop(items, others)
    items.each do |item|
      others.each do |other|
        break if other.done?
        publish(other)
      end
      after_inner(item)
    end
    finish(items)
  end
end
