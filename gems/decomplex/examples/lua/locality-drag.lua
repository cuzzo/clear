function run(user, cart, logger)
  local receipt_id = user.id

  local total = cart.total
  if total > 100 then
    if cart.discountable() then
      local discount = 10
    end
  end
  if cart.taxable() then
    if cart.region then
      local tax = total * 2
    end
  end
  if logger.enabled() then
    if logger.debug() then
      logger.info(total)
    end
  end
  if cart.valid() then
    if cart.ready() then
      local status = 1
    end
  end

  emit(receipt_id)
end
