local function make_item(i)
    local r = i % 3
    if r == 0 then
        return { tag = "Boxed", box = { p = { x = i, y = i * 2 }, weight = i % 7 } }
    elseif r == 1 then
        return { tag = "Raw", n = i * 5 }
    end
    return { tag = "Empty" }
end

local function score_item(item)
    if item.tag == "Boxed" then
        return item.box.p.x + item.box.p.y + item.box.weight
    elseif item.tag == "Raw" then
        return item.n - 3
    end
    return 1
end

local t0 = os.clock()
local total = 0
for i = 0, 99999 do
    total = total + score_item(make_item(i))
end
local total_ms = (os.clock() - t0) * 1000
print("total = " .. tostring(total))
print(string.format("BENCH_RESULT: %.3f ms", total_ms))
