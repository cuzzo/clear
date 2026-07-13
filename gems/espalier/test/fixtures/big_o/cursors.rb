def amortized_scan(text)
  index = 0
  while index < text.length
    cursor = index + 1
    while cursor < text.length
      cursor += 1
    end
    index = cursor
  end
end

def independent_scan(items)
  left = 0
  while left < items.length
    right = 0
    while right < items.length
      consume(left, right)
      right += 1
    end
    left += 1
  end
end
