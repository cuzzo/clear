# frozen_string_literal: true

class Billing
  def mixed(price, tax, logger)
    subtotal = price + tax
    total = subtotal * 2
    rounded = total.round

    timestamp = Time.now
    buffer = []
    buffer << timestamp
    logger.info(buffer)

    [rounded, buffer]
  end
end
