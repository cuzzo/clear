func mixed(price: Int, tax: Int) -> Result {
  let subtotal = price + tax
  let total = subtotal.round()

  let timestamp = now()
  let buffer = Buffer.init()
  buffer.push(timestamp)
  return Result.init(total, buffer)
}
