struct WeightedInlineExample;

impl WeightedInlineExample {
    fn checkout(&self, user: User, cart: Cart) {
        self.validate_user(user);
        self.apply_discount(cart);
        self.process_payment(user, cart);
        self.audit_cart(cart);
    }

    fn validate_user(&self, user: User) -> bool {
        if user.active() && !user.suspended() {
            if user.profile.complete() { true } else { false }
        } else {
            false
        }
    }

    fn apply_discount(&self, cart: Cart) -> i32 {
        if cart.total > 100 && eligible() {
            if holiday() { 20 } else if loyalty_month() { 15 } else { 10 }
        } else {
            0
        }
    }

    fn process_payment(&self, user: User, cart: Cart) {
        if gateway.ready() {
            if cart.total > 0 && user.active() {
                if fraud_check(user) { charge(user, cart); } else { decline(user); }
            }
        }
    }

    fn audit_cart(&self, cart: Cart) {
        for item in cart.items {
            if item.taxable() {
                if item.region && item.amount > 0 {
                    record_tax(item);
                }
            }
        }
    }
}
