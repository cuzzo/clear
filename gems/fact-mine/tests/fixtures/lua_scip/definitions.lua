local Calculator = {}

function Calculator.double(value)
  return value * 2
end

function Calculator.render(values)
  table.sort(values)
  return table.concat(values, ",")
end

return Calculator
