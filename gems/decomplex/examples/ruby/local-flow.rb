# frozen_string_literal: true

class Billing
  def mixed(price, tax)
    subtotal = price + tax
    total = subtotal.round

    timestamp = Time.now
    buffer = []
    buffer << timestamp
    [total, buffer]
  end
end
