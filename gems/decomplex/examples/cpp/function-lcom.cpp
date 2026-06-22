Result mixed(int price, int tax, Logger logger) {
  auto subtotal = price + tax;
  auto total = subtotal * 2;
  auto rounded = total.round();

  auto timestamp = now();
  auto buffer = Buffer.init();
  buffer.push(timestamp);
  logger.info(buffer);

  return Result.init(rounded, buffer);
}
