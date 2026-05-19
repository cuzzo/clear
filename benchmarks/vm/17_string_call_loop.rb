def pick_label(i)
  case i % 4
  when 0 then "alpha"
  when 1 then "beta"
  when 2 then "gamma"
  else "delta"
  end
end

def label_score(label)
  case label
  when "alpha" then 11
  when "beta" then 17
  when "gamma" then 23
  else 31
  end
end

def nested_score(i)
  label_score(pick_label(i))
end

t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
total = 0
120_000.times do |i|
  total += nested_score(i)
end
total_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
puts "total = #{total}"
puts format("BENCH_RESULT: %.3f ms", total_ms)
