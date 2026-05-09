Point = Struct.new(:x, :y)
Box = Struct.new(:p, :weight)
Boxed = Struct.new(:box)
Raw = Struct.new(:n)
Empty = Object.new

def make_item(i)
  case i % 3
  when 0
    Boxed.new(Box.new(Point.new(i, i * 2), i % 7))
  when 1
    Raw.new(i * 5)
  else
    Empty
  end
end

def score_item(item)
  case item
  when Boxed
    item.box.p.x + item.box.p.y + item.box.weight
  when Raw
    item.n - 3
  else
    1
  end
end

t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
total = 0
100_000.times do |i|
  total += score_item(make_item(i))
end
total_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
puts "total = #{total}"
puts format("BENCH_RESULT: %.3f ms", total_ms)
