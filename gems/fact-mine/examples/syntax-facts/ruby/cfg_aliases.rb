class Inventory
  def borrowed
    items = T.let(@items, T::Array[String])
    return items
  end

  def copied
    copy = @items.dup
    return copy
  end
end
