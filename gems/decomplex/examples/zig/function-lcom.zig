pub fn mixed(price: i32, tax: i32, logger: Logger) Result {
    const subtotal = price + tax;
    const total = subtotal * 2;
    const rounded = total.round();

    const timestamp = now();
    var buffer = Buffer.init();
    buffer.push(timestamp);
    logger.info(buffer);

    return Result.init(rounded, buffer);
}
