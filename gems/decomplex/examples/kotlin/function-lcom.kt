fun mixed(price: Int, tax: Int, logger: Logger): Result {
  val subtotal = price + tax
  val total = subtotal * 2
  val rounded = total.round()

  val timestamp = now()
  val buffer = Buffer.init()
  buffer.push(timestamp)
  logger.info(buffer)

  return Result.init(rounded, buffer)
}
