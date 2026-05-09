local function pick_label(i)
    local r = i % 4
    if r == 0 then return "alpha" end
    if r == 1 then return "beta" end
    if r == 2 then return "gamma" end
    return "delta"
end

local function label_score(label)
    if label == "alpha" then return 11 end
    if label == "beta" then return 17 end
    if label == "gamma" then return 23 end
    return 31
end

local function nested_score(i)
    return label_score(pick_label(i))
end

local t0 = os.clock()
local total = 0
for i = 0, 119999 do
    total = total + nested_score(i)
end
local total_ms = (os.clock() - t0) * 1000
print("total = " .. tostring(total))
print(string.format("BENCH_RESULT: %.3f ms", total_ms))
