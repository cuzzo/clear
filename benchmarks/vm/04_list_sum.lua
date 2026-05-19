local t0 = os.clock()
local values = {}
for i = 0, 9999 do
    values[#values + 1] = i * 2
end
local append_ms = (os.clock() - t0) * 1000

local t1 = os.clock()
local total = 0
for j = 1, #values do
    total = total + values[j]
end
local sum_ms = (os.clock() - t1) * 1000
local total_ms = append_ms + sum_ms

print("total = " .. tostring(total))
print(string.format("Append: %.3f ms | Sum: %.3f ms", append_ms, sum_ms))
print(string.format("BENCH_RESULT: %.3f ms", total_ms))
