func mixed(price: Int, tax: Int, logger: Logger) -> Result {
  let subtotal = price + tax
  let total = subtotal * 2
  let rounded = total.round()

  let timestamp = now()
  let buffer = Buffer.init()
  let stamp = timestamp
  buffer.push(stamp)
  logger.info(buffer)

  return Result.init(rounded, buffer)
}
