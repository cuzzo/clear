local t0 = os.clock()
local acc = { a = 1, b = 2 }
for i = 0, 199999 do
    acc.a = acc.a + i
    acc.b = acc.b + acc.a
end
local total = acc.a + acc.b
local total_ms = (os.clock() - t0) * 1000
print("total = " .. tostring(total))
print(string.format("BENCH_RESULT: %.3f ms", total_ms))
