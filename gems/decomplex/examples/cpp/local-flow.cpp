Result mixed(int price, int tax) {
  auto subtotal = price + tax;
  auto total = subtotal.round();

  auto timestamp = now();
  auto buffer = Buffer.init();
  buffer.push(timestamp);
  return Result.init(total, buffer);
}
