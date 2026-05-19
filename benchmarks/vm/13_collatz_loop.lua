local t0 = os.clock()
local total_steps = 0
local checksum = 0
local seed = 1
while seed <= 2000 do
    local n = seed
    local steps = 0
    while n ~= 1 do
        if (n % 2) == 0 then
            n = n // 2
        else
            n = (n * 3) + 1
        end
        steps = steps + 1
    end
    total_steps = total_steps + steps
    checksum = checksum + (steps * seed)
    seed = seed + 1
end
local total_ms = (os.clock() - t0) * 1000
print("steps = " .. tostring(total_steps))
print("checksum = " .. tostring(checksum))
print(string.format("BENCH_RESULT: %.3f ms", total_ms))
