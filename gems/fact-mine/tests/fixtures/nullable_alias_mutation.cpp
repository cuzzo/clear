extern int *load_value(void);

int use_after_slot_update(void) {
  int *value = nullptr;
  int **slot = &value;
  *slot = load_value();
  return *value;
}
