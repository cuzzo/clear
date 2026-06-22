# frozen_string_literal: true

class WeightedInlineExample
  def checkout(user, cart)
    validate_user(user)
    apply_discount(cart)
    process_payment(user, cart)
    audit_cart(cart)
  end

  private

  def validate_user(user)
    return false unless user
    if user.active? && !user.suspended?
      if user.profile.complete?
        true
      else
        false
      end
    else
      false
    end
  end

  def apply_discount(cart)
    if cart.total > 100 && eligible?
      if holiday?
        20
      elsif loyalty_month?
        15
      else
        10
      end
    end
  end

  def process_payment(user, cart)
    if gateway.ready?
      if cart.total > 0 && user.active?
        if fraud_check(user)
          charge(user, cart)
        else
          decline(user)
        end
      end
    end
  end

  def audit_cart(cart)
    cart.items.each do |item|
      if item.taxable?
        if item.region && item.amount > 0
          record_tax(item)
        end
      end
    end
  end
end
