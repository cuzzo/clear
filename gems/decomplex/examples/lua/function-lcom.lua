function mixed(price, tax, logger)
  local subtotal = price + tax
  local total = subtotal * 2
  local rounded = total.round()

  local timestamp = now()
  local buffer = Buffer.init()
  buffer.push(timestamp)
  logger.info(buffer)

  return Result.init(rounded, buffer)
end
