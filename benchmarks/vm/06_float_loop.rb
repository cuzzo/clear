t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
x = 1.0
100_000.times do
  x = (x + 1.25) * 1.000001 - 0.25
end
total_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
puts "x = #{x.to_i}"
puts format("BENCH_RESULT: %.3f ms", total_ms)
