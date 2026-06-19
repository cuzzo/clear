class Example {
  static void run(User user, Cart cart, Logger logger) {
    var receipt_id = user.id;

    var total = cart.total;
    if (total > 100) {
      if (cart.discountable()) {
        var discount = 10;
      }
    }
    if (cart.taxable()) {
      if (cart.region) {
        var tax = total * 2;
      }
    }
    if (logger.enabled()) {
      if (logger.debug()) {
        logger.info(total);
      }
    }
    if (cart.valid()) {
      if (cart.ready()) {
        var status = 1;
      }
    }

    emit(receipt_id);
  }
}
