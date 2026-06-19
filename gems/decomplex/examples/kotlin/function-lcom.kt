fun mixed(price: Int, tax: Int, logger: Logger): Result {
  val subtotal = price + tax
  val total = subtotal * 2
  val rounded = total.round()

  val timestamp = now()
  val buffer = Buffer.init()
  val stamp = timestamp
  buffer.push(stamp)
  logger.info(buffer)

  return Result.init(rounded, buffer)
}
