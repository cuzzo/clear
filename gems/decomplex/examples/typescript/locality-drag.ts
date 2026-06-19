function run(user: User, cart: Cart, logger: Logger) {
  const receipt_id = user.id;

  const total = cart.total;
  if (total > 100) {
    if (cart.discountable()) {
      const discount = 10;
    }
  }
  if (cart.taxable()) {
    if (cart.region) {
      const tax = total * 2;
    }
  }
  if (logger.enabled()) {
    if (logger.debug()) {
      logger.info(total);
    }
  }
  if (cart.valid()) {
    if (cart.ready()) {
      const status = 1;
    }
  }

  emit(receipt_id);
}
