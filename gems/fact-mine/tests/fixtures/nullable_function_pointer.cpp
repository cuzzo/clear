void invoke_null_callback() {
  void (*callback)();
  callback = nullptr;
  callback();
}
