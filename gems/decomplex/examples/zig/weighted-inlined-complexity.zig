const WeightedInlineExample = struct {
    pub fn checkout(self: *WeightedInlineExample, user: User, cart: Cart) void {
        self.validate_user(user);
        self.apply_discount(cart);
        self.process_payment(user, cart);
        self.audit_cart(cart);
    }

    fn validate_user(self: *WeightedInlineExample, user: User) bool {
        _ = self;
        if (user.active() and !user.suspended()) {
            if (user.profile.complete()) { return true; } else { return false; }
        } else {
            return false;
        }
    }

    fn apply_discount(self: *WeightedInlineExample, cart: Cart) i32 {
        _ = self;
        if (cart.total > 100 and eligible()) {
            if (holiday()) { return 20; } else if (loyalty_month()) { return 15; } else { return 10; }
        }
        return 0;
    }

    fn process_payment(self: *WeightedInlineExample, user: User, cart: Cart) void {
        _ = self;
        if (gateway.ready()) {
            if (cart.total > 0 and user.active()) {
                if (fraud_check(user)) { charge(user, cart); } else { decline(user); }
            }
        }
    }

    fn audit_cart(self: *WeightedInlineExample, cart: Cart) void {
        _ = self;
        for (cart.items) |item| {
            if (item.taxable()) {
                if (item.region and item.amount > 0) {
                    record_tax(item);
                }
            }
        }
    }
};
