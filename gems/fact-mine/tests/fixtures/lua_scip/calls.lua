local Calculator = require("definitions")

local function calculate(value)
  return Calculator.double(value)
end

local function display(values)
  return Calculator.render(values)
end

return {
  calculate = calculate,
  display = display,
}
