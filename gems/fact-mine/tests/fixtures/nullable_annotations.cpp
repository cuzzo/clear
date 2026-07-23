struct Widget {
  int value;
};

namespace gsl {
template <typename T>
struct not_null {
  T value;
};
}

int non_null_parameter(gsl::not_null<Widget *> value) {
  return value->value;
}

extern gsl::not_null<Widget *> load_widget(void);

int non_null_local(void) {
  gsl::not_null<Widget *> value = load_widget();
  return value->value;
}
