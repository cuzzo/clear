function checkout(user, cart) { validate_user(user); apply_discount(cart); process_payment(user, cart); audit_cart(cart); }
function validate_user(user) { if (user.active() && !user.suspended()) { if (user.profile.complete()) { return true; } else { return false; } } else { return false; } }
function apply_discount(cart) { if (cart.total > 100 && eligible()) { if (holiday()) { return 20; } else if (loyalty_month()) { return 15; } else { return 10; } } return 0; }
function process_payment(user, cart) { if (gateway.ready()) { if (cart.total > 0 && user.active()) { if (fraud_check(user)) { charge(user, cart); } else { decline(user); } } } }
function audit_cart(cart) { for (const item of cart.items) { if (item.taxable()) { if (item.region && item.amount > 0) { record_tax(item); } } } }
