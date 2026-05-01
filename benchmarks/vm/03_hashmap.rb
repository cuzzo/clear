t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
m = {}
100_000.times { |i| m[i] = i * 2 }
insert_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
total = 0
100_000.times { |j| total += (m[j] || 0) }
lookup_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t1) * 1000
total_ms = (insert_ms + lookup_ms).to_i
puts "total = #{total}"
puts "Insert: #{insert_ms.to_i} ms | Lookup: #{lookup_ms.to_i} ms"
puts "BENCH_RESULT: #{total_ms} ms"
