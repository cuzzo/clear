class Example { static Result mixed(int price, int tax, Logger logger) {
  var subtotal = price + tax;
  var total = subtotal * 2;
  var rounded = total.round();

  var timestamp = now();
  var buffer = Buffer.init();
  var stamp = timestamp;
  buffer.push(stamp);
  logger.info(buffer);

  return Result.init(rounded, buffer);
} }
