line = "SET:12345:payload"
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
total = 0
50_000.times do
  if line.start_with?("SET:") && line.include?("payload")
    total += line[4, 5].length
  end
end
total_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
puts "total = #{total}"
puts format("BENCH_RESULT: %.3f ms", total_ms)
