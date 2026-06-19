def mixed(price, tax):
    subtotal = price + tax
    total = subtotal.round()

    timestamp = now()
    buffer = Buffer()
    buffer.push(timestamp)
    return Result(total, buffer)
