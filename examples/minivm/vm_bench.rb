#!/usr/bin/env ruby
# Equivalent of vm_bench.clear: 100 outer * 10000 inner filter+sum.

sum = 0
100.times do
  i = 0
  while i < 10000
    sum += i if i.even?
    i += 1
  end
end
raise "bad sum: #{sum}" unless sum == 2_499_500_000
