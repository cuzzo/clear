t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
values = []
10_000.times { |i| values << i * 2 }
append_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
total = 0
values.length.times { |j| total += values[j] }
sum_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t1) * 1000
total_ms = append_ms + sum_ms
puts "total = #{total}"
puts format("Append: %.3f ms | Sum: %.3f ms", append_ms, sum_ms)
puts format("BENCH_RESULT: %.3f ms", total_ms)
