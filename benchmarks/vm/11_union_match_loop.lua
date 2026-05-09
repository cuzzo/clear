local function make_value(i)
    local r = i % 3
    if r == 0 then
        return { tag = "a", payload = i }
    elseif r == 1 then
        return { tag = "b", payload = i * 2 }
    end
    return { tag = "c" }
end

local t0 = os.clock()
local total = 0
for i = 0, 99999 do
    local v = make_value(i)
    if v.tag == "a" then
        total = total + v.payload
    elseif v.tag == "b" then
        total = total - v.payload
    else
        total = total + 1
    end
end
local total_ms = (os.clock() - t0) * 1000
print("total = " .. tostring(total))
print(string.format("BENCH_RESULT: %.3f ms", total_ms))
