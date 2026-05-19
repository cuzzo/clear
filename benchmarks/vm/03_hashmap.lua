local t0 = os.clock()
local m = {}
for i = 0, 99999 do
    m[i] = i * 2
end
local insert_ms = (os.clock() - t0) * 1000

local t1 = os.clock()
local total = 0
for j = 0, 99999 do
    total = total + (m[j] or 0)
end
local lookup_ms = (os.clock() - t1) * 1000
local total_ms = math.floor(insert_ms + lookup_ms)

print("total = " .. tostring(total))
print("Insert: " .. tostring(math.floor(insert_ms)) .. " ms | Lookup: " .. tostring(math.floor(lookup_ms)) .. " ms")
print("BENCH_RESULT: " .. tostring(total_ms) .. " ms")
