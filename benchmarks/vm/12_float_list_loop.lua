local t0 = os.clock()
local values = {}
local current = 0.0
for _ = 1, 5000 do
    values[#values + 1] = current
    current = current + 1.5
end
for j = 1, #values do
    values[j] = values[j] + 0.25
end
local total = 0.0
for k = 1, #values do
    total = total + values[k]
end
local total_ms = (os.clock() - t0) * 1000
print("total = " .. tostring(math.floor(total)))
print(string.format("BENCH_RESULT: %.3f ms", total_ms))
