local t0 = os.clock()
local m = {}
for i = 0, 59999 do
    m[i] = i * 3
end

local total = 0
local hits = 0
for j = 0, 59999 do
    if m[j] ~= nil then
        hits = hits + 1
        total = total + m[j]
    end
    if (j % 4) == 0 then
        m[j] = nil
    end
end

local survivors = 0
for k = 0, 59999 do
    if m[k] ~= nil then
        survivors = survivors + 1
    end
end

local count = survivors
local score = total + (hits * 7) + (survivors * 11) + count
local total_ms = (os.clock() - t0) * 1000
print("count = " .. tostring(count))
print("score = " .. tostring(score))
print(string.format("BENCH_RESULT: %.3f ms", total_ms))
