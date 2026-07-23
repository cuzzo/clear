int dereference_null() {
  int* value;
  value = nullptr;
  return *value;
}
