class CfgCallbacks
  def transaction_block(user)
    transaction do
      audit(user)
    end
    finish(user)
  end

  def iterator_block(items)
    items.each do |item|
      publish(item)
    end
    finish(items)
  end

  def nested_callback(user)
    transaction do
      around_hook do
        audit(user)
      end
    end
    finish(user)
  end

  def yield_site(user)
    before(user)
    yield user
    after(user)
  end

  def empty_callback(user)
    transaction do
    end
    finish(user)
  end
end
