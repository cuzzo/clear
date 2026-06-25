# frozen_string_literal: true

def check
  @cached = @source + 1
  @source = 2
  puts @cached
end
