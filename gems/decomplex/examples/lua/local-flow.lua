function mixed(price, tax)
  local subtotal = price + tax
  local total = subtotal.round()

  local timestamp = now()
  local buffer = Buffer.init()
  buffer.push(timestamp)
  return Result.init(total, buffer)
end
