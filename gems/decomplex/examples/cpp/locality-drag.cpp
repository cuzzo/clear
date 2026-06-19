void run(User user, Cart cart, Logger logger) {
  auto receipt_id = user.id;

  auto total = cart.total;
  if (total > 100) {
    if (cart.discountable()) {
      auto discount = 10;
    }
  }
  if (cart.taxable()) {
    if (cart.region) {
      auto tax = total * 2;
    }
  }
  if (logger.enabled()) {
    if (logger.debug()) {
      logger.info(total);
    }
  }
  if (cart.valid()) {
    if (cart.ready()) {
      auto status = 1;
    }
  }

  emit(receipt_id);
}
