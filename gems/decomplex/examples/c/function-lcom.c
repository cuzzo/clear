Result mixed(int price, int tax, Logger logger) {
  int subtotal = price + tax;
  int total = subtotal * 2;
  int rounded = total.round();

  int timestamp = now();
  Buffer buffer = Buffer_init();
  int stamp = timestamp;
  buffer.push(stamp);
  logger.info(buffer);

  return Result_init(rounded, buffer);
}
