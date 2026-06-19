func mixed(price: Int, tax: Int, logger: Logger) -> Result {
  let subtotal = price + tax
  let total = subtotal * 2
  let rounded = total.round()

  let timestamp = now()
  let buffer = Buffer.init()
  buffer.push(timestamp)
  logger.info(buffer)

  return Result.init(rounded, buffer)
}
