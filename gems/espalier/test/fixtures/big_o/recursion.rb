def fib(n)
  return n if n <= 1
  fib(n - 1) + fib(n - 2)
end

def binary_search(n)
  return if n <= 1
  binary_search(n / 2)
end

def permute(items)
  return [[]] if items.empty?
  items.each do |item|
    remaining = items - [item]
    permute(remaining)
  end
end

def recurse_unknown(items)
  recurse_unknown(transform(items))
end
