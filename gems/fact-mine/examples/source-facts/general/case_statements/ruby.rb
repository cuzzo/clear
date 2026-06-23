def method_eight(x)
  case x
  when 1, 2
    action_one
  when 3
    action_two
  else
    action_three
  end
end

def method_case_no_val(x)
  case
  when x == 1
    action_one
  end
end

def method_case_one_pattern(x)
  case x
  when 1
    action_one
  end
end
