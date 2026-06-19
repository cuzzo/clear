fn mixed(price: i32, tax: i32) -> (i32, Buffer) {
    let subtotal = price + tax;
    let total = subtotal.round();

    let timestamp = now();
    let mut buffer = Buffer::new();
    buffer.push(timestamp);
    (total, buffer)
}
