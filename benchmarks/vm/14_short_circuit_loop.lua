local t0 = os.clock()
local hits = 0
local skips = 0
local i = 0
while i < 200000 do
    local d = i % 11
    if d ~= 0 and (100 // d) > 9 then
        hits = hits + 1
    end
    if d == 0 or (100 // d) < 4 then
        skips = skips + 1
    end
    i = i + 1
end
local score = (hits * 3) + (skips * 7)
local total_ms = (os.clock() - t0) * 1000
print("hits = " .. tostring(hits))
print("skips = " .. tostring(skips))
print("score = " .. tostring(score))
print(string.format("BENCH_RESULT: %.3f ms", total_ms))
