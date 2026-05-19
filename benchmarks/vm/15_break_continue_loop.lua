local t0 = os.clock()
local total = 0
local seen = 0
for i = 0, 299999 do
    if i > 123456 then
        break
    end
    if (i % 17) ~= 0 then
        seen = seen + 1
        if (i % 5) == 0 then
            total = total + (i * 2)
        else
            total = total + i
        end
    end
end
local score = total + (seen * 11)
local total_ms = (os.clock() - t0) * 1000
print("seen = " .. tostring(seen))
print("score = " .. tostring(score))
print(string.format("BENCH_RESULT: %.3f ms", total_ms))
