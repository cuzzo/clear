t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
nums = (0...10000).to_a
sum = 0
nums.each { |n| sum += n if n.even? }
puts "sum = #{sum}"
puts "BENCH_RESULT: #{((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).to_i} ms"
