package main
func mixed(price int, tax int, logger Logger) Result {
  subtotal := price + tax
  total := subtotal * 2
  rounded := total.round()

  timestamp := now()
  buffer := Buffer_init()
  stamp := timestamp
  buffer.push(stamp)
  logger.info(buffer)

  return Result_init(rounded, buffer)
}
