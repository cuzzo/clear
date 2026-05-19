t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
m = {}
60_000.times do |i|
  m[i] = i * 3
end

total = 0
hits = 0
60_000.times do |j|
  if m.key?(j)
    hits += 1
    total += m.fetch(j, 0)
  end
  m.delete(j) if (j % 4) == 0
end

survivors = 0
60_000.times do |k|
  survivors += 1 if m.key?(k)
end

count = m.length
score = total + (hits * 7) + (survivors * 11) + count
total_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
puts "count = #{count}"
puts "score = #{score}"
puts format("BENCH_RESULT: %.3f ms", total_ms)
