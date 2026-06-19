package main
func mixed(price int, tax int) Result {
  subtotal := price + tax
  total := subtotal.round()

  timestamp := now()
  buffer := Buffer_init()
  buffer.push(timestamp)
  return Result_init(total, buffer)
}
