local t0 = os.clock()
local x = 1.0
for _ = 0, 99999 do
    x = (x + 1.25) * 1.000001 - 0.25
end
local total_ms = (os.clock() - t0) * 1000
print("x = " .. tostring(math.floor(x)))
print(string.format("BENCH_RESULT: %.3f ms", total_ms))
