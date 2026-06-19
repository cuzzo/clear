pub fn mixed(price: i32, tax: i32) Result {
    const subtotal = price + tax;
    const total = subtotal.round();

    const timestamp = now();
    var buffer = Buffer.init();
    buffer.push(timestamp);
    return Result.init(total, buffer);
}
