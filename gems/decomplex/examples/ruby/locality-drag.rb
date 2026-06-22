# frozen_string_literal: true

class Importer
  def run(user, cart, logger)
    receipt_id = user.id

    total = cart.total
    if total > 100
      if cart.discountable?
        discount = 10
      end
    end
    if cart.taxable?
      if cart.region
        tax = total * 0.2
      end
    end
    if logger.enabled?
      if logger.debug?
        logger.info(total)
      end
    end
    if cart.valid?
      if cart.ready?
        status = :ready
      end
    end

    emit(receipt_id)
  end
end
