def fib(n)
    return n if n <= 1
    fib(n-1) + fib(n-2)
end
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
r = fib(25)
puts "fib(25) = #{r}"
puts "BENCH_RESULT: #{((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).to_i} ms"
