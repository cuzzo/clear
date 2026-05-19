local function mix(x)
    return (x * 3) + 1
end

local t0 = os.clock()
local total = 0
for i = 0, 99999 do
    total = total + mix(i)
end
local total_ms = (os.clock() - t0) * 1000
print("total = " .. tostring(total))
print(string.format("BENCH_RESULT: %.3f ms", total_ms))
