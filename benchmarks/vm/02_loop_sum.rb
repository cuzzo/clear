t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
total = 0
1_000_000.times { |i| total += i }
puts "sum = #{total}"
puts "BENCH_RESULT: #{((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).to_i} ms"
