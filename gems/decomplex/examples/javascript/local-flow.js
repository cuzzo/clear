function mixed(price, tax) {
  const subtotal = price + tax;
  const total = subtotal.round();

  const timestamp = now();
  const buffer = Buffer.init();
  buffer.push(timestamp);
  return Result.init(total, buffer);
}
