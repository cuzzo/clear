local t0 = os.clock()
local total = 0
for i = 0, 199999 do
    local r = i % 5
    if r == 0 then
        total = total + i
    elseif r == 1 then
        total = total - i
    elseif r == 2 then
        total = total + (i * 2)
    else
        total = total + 1
    end
end
local total_ms = (os.clock() - t0) * 1000
print("total = " .. tostring(total))
print(string.format("BENCH_RESULT: %.3f ms", total_ms))
