#!/usr/bin/env ruby
# Benchmark: tight integer loop summing 0..9_999_999.
# Run with: ruby --disable=jit bench_loop.rb

N = 10_000_000
ITERS = 3

# Verify
s = 0
(0...N).each { |i| s += i }
raise "bad sum" unless s == N * (N - 1) / 2
puts "sum(0..#{N-1}) = #{s}"

start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
ITERS.times do
  s = 0
  (0...N).each { |i| s += i }
end
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

puts "Ruby (no JIT): #{ITERS} iterations in #{(elapsed * 1000).round}ms"
puts "  #{(elapsed * 1000 / ITERS).round(2)}ms per iteration"
