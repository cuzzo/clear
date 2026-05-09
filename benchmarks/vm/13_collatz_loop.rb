t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
total_steps = 0
checksum = 0
seed = 1
while seed <= 2000
  n = seed
  steps = 0
  while n != 1
    if (n % 2) == 0
      n /= 2
    else
      n = (n * 3) + 1
    end
    steps += 1
  end
  total_steps += steps
  checksum += steps * seed
  seed += 1
end
total_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
puts "steps = #{total_steps}"
puts "checksum = #{checksum}"
puts format("BENCH_RESULT: %.3f ms", total_ms)
