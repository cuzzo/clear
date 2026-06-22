fun run(user: User, cart: Cart, logger: Logger) {
  val receipt_id = user.id

  val total = cart.total
  if (total > 100) {
    if (cart.discountable()) {
      val discount = 10
    }
  }
  if (cart.taxable()) {
    if (cart.region) {
      val tax = total * 2
    }
  }
  if (logger.enabled()) {
    if (logger.debug()) {
      logger.info(total)
    }
  }
  if (cart.valid()) {
    if (cart.ready()) {
      val status = 1
    }
  }

  emit(receipt_id)
}
