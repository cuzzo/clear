def mix(x)
  (x * 3) + 1
end

t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
total = 0
100_000.times { |i| total += mix(i) }
total_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
puts "total = #{total}"
puts format("BENCH_RESULT: %.3f ms", total_ms)
