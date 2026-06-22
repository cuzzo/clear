package main
func run(user User, cart Cart, logger Logger) {
  receipt_id := user.id

  total := cart.total
  if total > 100 {
    if cart.discountable() {
      discount := 10
      _ = discount
    }
  }
  if cart.taxable() {
    if cart.region {
      tax := total * 2
      _ = tax
    }
  }
  if logger.enabled() {
    if logger.debug() {
      logger.info(total)
    }
  }
  if cart.valid() {
    if cart.ready() {
      status := 1
      _ = status
    }
  }

  emit(receipt_id)
}
