function mixed(price: number, tax: number, logger: Logger) {
  const subtotal = price + tax;
  const total = subtotal * 2;
  const rounded = total.round();

  const timestamp = now();
  const buffer = Buffer.init();
  buffer.push(timestamp);
  logger.info(buffer);

  return Result.init(rounded, buffer);
}
