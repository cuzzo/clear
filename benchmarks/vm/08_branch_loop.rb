t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
total = 0
200_000.times do |i|
  r = i % 5
  if r == 0
    total += i
  elsif r == 1
    total -= i
  elsif r == 2
    total += i * 2
  else
    total += 1
  end
end
total_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
puts "total = #{total}"
puts format("BENCH_RESULT: %.3f ms", total_ms)
