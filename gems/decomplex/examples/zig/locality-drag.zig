pub fn run(user: User, cart: Cart, logger: Logger) void {
    const receipt_id = user.id;

    const total = cart.total;
    if (total > 100) {
        if (cart.discountable()) {
            const discount = 10;
            _ = discount;
        }
    }
    if (cart.taxable()) {
        if (cart.region) {
            const tax = total * 2;
            _ = tax;
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
            _ = status;
        }
    }

    emit(receipt_id);
}
