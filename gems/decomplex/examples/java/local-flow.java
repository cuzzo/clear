class Example { static Result mixed(int price, int tax) {
  var subtotal = price + tax;
  var total = subtotal.round();

  var timestamp = now();
  var buffer = Buffer.init();
  buffer.push(timestamp);
  return Result.init(total, buffer);
} }
