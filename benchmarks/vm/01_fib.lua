local function fib(n)
    if n <= 1 then return n end
    return fib(n - 1) + fib(n - 2)
end

local t0 = os.clock()
local r = fib(25)
print("fib(25) = " .. tostring(r))
print("BENCH_RESULT: " .. tostring(math.floor((os.clock() - t0) * 1000)) .. " ms")
