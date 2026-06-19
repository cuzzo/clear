void checkout(User user, Cart cart) { validate_user(user); apply_discount(cart); process_payment(user, cart); audit_cart(cart); }
bool validate_user(User user) { if (user.active() && !user.suspended()) { if (user.profile.complete()) { return true; } else { return false; } } else { return false; } }
int apply_discount(Cart cart) { if (cart.total > 100 && eligible()) { if (holiday()) { return 20; } else if (loyalty_month()) { return 15; } else { return 10; } } return 0; }
void process_payment(User user, Cart cart) { if (gateway.ready()) { if (cart.total > 0 && user.active()) { if (fraud_check(user)) { charge(user, cart); } else { decline(user); } } } }
void audit_cart(Cart cart) { for (auto item : cart.items) { if (item.taxable()) { if (item.region && item.amount > 0) { record_tax(item); } } } }
