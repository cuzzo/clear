t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
m = {}
50_000.times do |i|
  if (i % 2) == 0
    m["k_#{i}"] = i * 1.5
  else
    m["k_#{i}"] = "v_#{i}"
  end
end

insert_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

num_count = 0
str_count = 0
50_000.times do |j|
  v = m["k_#{j}"]
  case v
  when Float then num_count += 1
  when String then str_count += 1
  end
end

read_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t1) * 1000
total_ms = insert_ms + read_ms
puts "nums=#{num_count} strs=#{str_count}"
puts format("Insert: %d ms | Read: %d ms", insert_ms, read_ms)
puts format("BENCH_RESULT: %.3f ms", total_ms)
