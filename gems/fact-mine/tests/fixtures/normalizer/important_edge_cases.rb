case x
in 1
  return 1, 2
in MyConst
  return obj.method
in bare_name
  return !obj
end

def test_infix
  return a + b
end

def test_ternary
  return a ? b : c
end

def self_element_ref
  self[foo] = 1
end

def augmented_assignment
  a += 1
  @a += 1
end

module Foo
  class Bar
    private def visibility_test
      # private method
    end
  end
end

def test_unary_not
  !foo
end

