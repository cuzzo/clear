fn run(user: User, cart: Cart, logger: Logger) {
    let receipt_id = user.id;

    let total = cart.total;
    if total > 100 {
        if cart.discountable() {
            let discount = 10;
        }
    }
    if cart.taxable() {
        if cart.region {
            let tax = total * 2;
        }
    }
    if logger.enabled() {
        if logger.debug() {
            logger.info(total);
        }
    }
    if cart.valid() {
        if cart.ready() {
            let status = 1;
        }
    }

    emit(receipt_id);
}
