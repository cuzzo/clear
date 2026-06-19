package main
func mixed(price int, tax int, logger Logger) Result {
  subtotal := price + tax
  total := subtotal * 2
  rounded := total.round()

  timestamp := now()
  buffer := Buffer_init()
  buffer.push(timestamp)
  logger.info(buffer)

  return Result_init(rounded, buffer)
}
