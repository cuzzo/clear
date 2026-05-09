local line = "SET:12345:payload"
local t0 = os.clock()
local total = 0
for _ = 0, 49999 do
    if string.sub(line, 1, 4) == "SET:" and string.find(line, "payload", 1, true) ~= nil then
        total = total + string.len(string.sub(line, 5, 9))
    end
end
local total_ms = (os.clock() - t0) * 1000
print("total = " .. tostring(total))
print(string.format("BENCH_RESULT: %.3f ms", total_ms))
