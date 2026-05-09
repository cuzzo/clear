t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
total = 0
seen = 0
(0...300_000).each do |i|
  break if i > 123_456
  next if (i % 17) == 0

  seen += 1
  if (i % 5) == 0
    total += i * 2
  else
    total += i
  end
end
score = total + (seen * 11)
total_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
puts "seen = #{seen}"
puts "score = #{score}"
puts format("BENCH_RESULT: %.3f ms", total_ms)
