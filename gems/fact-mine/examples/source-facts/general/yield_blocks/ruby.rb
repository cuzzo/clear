def method_three
  yield(1)
end

def method_with_empty_block
  [1].each {}
end
