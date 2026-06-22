package main
func checkout(user User, cart Cart) { validate_user(user); apply_discount(cart); process_payment(user, cart); audit_cart(cart) }
func validate_user(user User) bool { if user.active() && !user.suspended() { if user.profile.complete() { return true } else { return false } } else { return false } }
func apply_discount(cart Cart) int { if cart.total > 100 && eligible() { if holiday() { return 20 } else if loyalty_month() { return 15 } else { return 10 } }; return 0 }
func process_payment(user User, cart Cart) { if gateway.ready() { if cart.total > 0 && user.active() { if fraud_check(user) { charge(user, cart) } else { decline(user) } } } }
func audit_cart(cart Cart) { for _, item := range cart.items { if item.taxable() { if item.region && item.amount > 0 { record_tax(item) } } } }
