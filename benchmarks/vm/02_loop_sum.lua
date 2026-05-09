local t0 = os.clock()
local total = 0
for i = 0, 999999 do
    total = total + i
end
print("sum = " .. tostring(total))
print("BENCH_RESULT: " .. tostring(math.floor((os.clock() - t0) * 1000)) .. " ms")
