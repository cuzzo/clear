function checkout(user, cart) validate_user(user); apply_discount(cart); process_payment(user, cart); audit_cart(cart) end
function validate_user(user) if user.active() and not user.suspended() then if user.profile.complete() then return true else return false end else return false end end
function apply_discount(cart) if cart.total > 100 and eligible() then if holiday() then return 20 elseif loyalty_month() then return 15 else return 10 end end return 0 end
function process_payment(user, cart) if gateway.ready() then if cart.total > 0 and user.active() then if fraud_check(user) then charge(user, cart) else decline(user) end end end end
function audit_cart(cart) for item in cart.items do if item.taxable() then if item.region and item.amount > 0 then record_tax(item) end end end end
