Acc = Struct.new(:a, :b)

t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
acc = Acc.new(1, 2)
200_000.times do |i|
  acc.a = acc.a + i
  acc.b = acc.b + acc.a
end
total = acc.a + acc.b
total_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
puts "total = #{total}"
puts format("BENCH_RESULT: %.3f ms", total_ms)
