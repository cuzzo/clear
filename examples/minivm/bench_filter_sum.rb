#!/usr/bin/env ruby
# Benchmark: create array of 10000 integers, filter evens, sum them.
# Run with: ruby --disable=jit bench_filter_sum.rb

N = 10_000
ITERS = 100

# Warmup
nums = (0...N).to_a
evens = nums.select(&:even?)
total = evens.sum

puts "Sum of evens 0..#{N-1}: #{total}"
raise "bad sum" unless total == 24_995_000

start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
ITERS.times do
  nums = (0...N).to_a
  sum = 0
  nums.each { |n| sum += n if n.even? }
end
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

puts "Ruby (no JIT): #{ITERS} iterations in #{(elapsed * 1000).round}ms"
puts "  #{(elapsed * 1000 / ITERS).round(2)}ms per iteration"
