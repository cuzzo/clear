t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
items = []
100_000.times do |i|
  m3 = i % 3
  case m3
  when 0 then items << "tag_#{i}"
  when 1 then items << i.to_f
  else items << nil
  end
end

push_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

num_count = 0
num_sum = 0.0
str_count = 0
nil_count = 0
items.each do |e|
  case e
  when Float
    num_count += 1
    num_sum += e
  when String
    str_count += 1
  else
    nil_count += 1
  end
end

iter_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t1) * 1000
total_ms = push_ms + iter_ms
puts "nums=#{num_count} strs=#{str_count}"
puts "nils=#{nil_count}"
puts format("Push: %d ms | Iter: %d ms", push_ms, iter_ms)
puts format("BENCH_RESULT: %.3f ms", total_ms)
