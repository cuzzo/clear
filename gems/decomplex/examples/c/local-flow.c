Result mixed(int price, int tax) {
  int subtotal = price + tax;
  int total = subtotal.round();

  int timestamp = now();
  Buffer buffer = Buffer_init();
  buffer.push(timestamp);
  return Result_init(total, buffer);
}
