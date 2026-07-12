def settle(items)
  changed = true
  while changed
    changed = false
    items.each do |item|
      changed = true if resolve(item)
    end
  end
end


def settle_groups(groups)
  groups.each do |items|
    changed = true
    while changed
      changed = false
      items.each { |item| changed = true if resolve(item) }
    end
  end
end


def settle_groups_with_object(groups)
  groups.each_with_object({}) do |items, output|
    changed = true
    while changed
      changed = false
      items.each { |item| changed = true if resolve(item) }
    end
  end
end
