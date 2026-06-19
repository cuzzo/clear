fun mixed(price: Int, tax: Int): Result {
  val subtotal = price + tax
  val total = subtotal.round()

  val timestamp = now()
  val buffer = Buffer.init()
  buffer.push(timestamp)
  return Result.init(total, buffer)
}
