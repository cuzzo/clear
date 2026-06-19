def checkout(user, cart):
    validate_user(user)
    apply_discount(cart)
    process_payment(user, cart)
    audit_cart(cart)

def validate_user(user):
    if user.active() and not user.suspended():
        if user.profile.complete(): return True
        else: return False
    else: return False

def apply_discount(cart):
    if cart.total > 100 and eligible():
        if holiday(): return 20
        elif loyalty_month(): return 15
        else: return 10
    return 0

def process_payment(user, cart):
    if gateway.ready():
        if cart.total > 0 and user.active():
            if fraud_check(user): charge(user, cart)
            else: decline(user)

def audit_cart(cart):
    for item in cart.items:
        if item.taxable():
            if item.region and item.amount > 0:
                record_tax(item)
