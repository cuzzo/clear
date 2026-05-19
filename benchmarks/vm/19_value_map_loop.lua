local t0 = os.clock()
local m = {}
for i = 0, 49999 do
    if (i % 2) == 0 then
        m["k_" .. tostring(i)] = i * 1.5
    else
        m["k_" .. tostring(i)] = "v_" .. tostring(i)
    end
end

local insert_ms = (os.clock() - t0) * 1000
local t1 = os.clock()

local num_count = 0
local str_count = 0
for j = 0, 49999 do
    local v = m["k_" .. tostring(j)]
    if type(v) == "number" then
        num_count = num_count + 1
    elseif type(v) == "string" then
        str_count = str_count + 1
    end
end

local read_ms = (os.clock() - t1) * 1000
local total_ms = insert_ms + read_ms
print("nums=" .. tostring(num_count) .. " strs=" .. tostring(str_count))
print(string.format("Insert: %d ms | Read: %d ms", math.floor(insert_ms), math.floor(read_ms)))
print(string.format("BENCH_RESULT: %.3f ms", total_ms))
