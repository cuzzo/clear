local t0 = os.clock()
local items = {}
for i = 0, 99999 do
    local m3 = i % 3
    if m3 == 0 then
        items[i + 1] = "tag_" .. tostring(i)
    elseif m3 == 1 then
        items[i + 1] = i + 0.0
    else
        items[i + 1] = false  -- sentinel for Nil
    end
end

local push_ms = (os.clock() - t0) * 1000
local t1 = os.clock()

local num_count = 0
local num_sum = 0.0
local str_count = 0
local nil_count = 0
local n = #items
for j = 1, n do
    local e = items[j]
    local t = type(e)
    if t == "number" then
        num_count = num_count + 1
        num_sum = num_sum + e
    elseif t == "string" then
        str_count = str_count + 1
    else
        nil_count = nil_count + 1
    end
end

local iter_ms = (os.clock() - t1) * 1000
local total_ms = push_ms + iter_ms
print("nums=" .. tostring(num_count) .. " strs=" .. tostring(str_count))
print("nils=" .. tostring(nil_count))
print(string.format("Push: %d ms | Iter: %d ms", math.floor(push_ms), math.floor(iter_ms)))
print(string.format("BENCH_RESULT: %.3f ms", total_ms))
