fn mixed(price: i32, tax: i32, logger: Logger) -> (i32, Buffer) {
    let subtotal = price + tax;
    let total = subtotal * 2;
    let rounded = total.round();

    let timestamp = now();
    let mut buffer = Buffer::new();
    buffer.push(timestamp);
    logger.info(buffer);

    (rounded, buffer)
}
