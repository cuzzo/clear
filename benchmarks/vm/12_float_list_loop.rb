t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
values = []
current = 0.0
5_000.times do
  values << current
  current += 1.5
end
values.length.times do |j|
  values[j] = values[j] + 0.25
end
total = 0.0
values.length.times do |k|
  total += values[k]
end
total_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
puts "total = #{total.to_i}"
puts format("BENCH_RESULT: %.3f ms", total_ms)
