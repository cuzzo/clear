typedef struct {
  int value;
} Widget;

extern Widget *load_widget(void);

int nullable_parameter(Widget * _Nullable value) {
  return value->value;
}

int non_null_parameter(Widget * _Nonnull value) {
  return value->value;
}

int nullable_local(void) {
  Widget * _Nullable value = load_widget();
  return *value;
}
