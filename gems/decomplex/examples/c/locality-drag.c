void run(User user, Cart cart, Logger logger) {
  int receipt_id = user.id;

  int total = cart.total;
  if (total > 100) {
    if (cart.discountable()) {
      int discount = 10;
    }
  }
  if (cart.taxable()) {
    if (cart.region) {
      int tax = total * 2;
    }
  }
  if (logger.enabled()) {
    if (logger.debug()) {
      logger.info(total);
    }
  }
  if (cart.valid()) {
    if (cart.ready()) {
      int status = 1;
    }
  }

  emit(receipt_id);
}
