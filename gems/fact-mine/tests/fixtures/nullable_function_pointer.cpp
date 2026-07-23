void invoke_null_callback() {
  void (*callback)();
  callback = nullptr;
  callback();
}

void invoke_uninitialized_callback() {
  void (*callback)();
  callback();
}
