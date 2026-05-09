t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
hits = 0
skips = 0
i = 0
while i < 200_000
  d = i % 11
  if d != 0 && (100 / d) > 9
    hits += 1
  end
  if d == 0 || (100 / d) < 4
    skips += 1
  end
  i += 1
end
score = (hits * 3) + (skips * 7)
total_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
puts "hits = #{hits}"
puts "skips = #{skips}"
puts "score = #{score}"
puts format("BENCH_RESULT: %.3f ms", total_ms)
