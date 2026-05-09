Value = Struct.new(:tag, :payload)

def make_value(i)
  case i % 3
  when 0
    Value.new(:a, i)
  when 1
    Value.new(:b, i * 2)
  else
    Value.new(:c, nil)
  end
end

t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
total = 0
100_000.times do |i|
  v = make_value(i)
  case v.tag
  when :a
    total += v.payload
  when :b
    total -= v.payload
  else
    total += 1
  end
end
total_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
puts "total = #{total}"
puts format("BENCH_RESULT: %.3f ms", total_ms)
