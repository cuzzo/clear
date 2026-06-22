def mixed(price, tax, logger):
    subtotal = price + tax
    total = subtotal * 2
    rounded = total.round()

    timestamp = now()
    buffer = Buffer()
    buffer.push(timestamp)
    logger.info(buffer)

    return Result(rounded, buffer)
