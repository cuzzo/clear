local function foo()
  if a then
    return 1
  elseif b then
    return 2
  else
    return 3
  end
end

for i=1,10 do
  if i == 5 then break end
end

for k,v in pairs({}) do
end
