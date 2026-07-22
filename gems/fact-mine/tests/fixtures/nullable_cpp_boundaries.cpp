template <typename T>
T *load_value();

using ValuePointer = int *;

#define LOAD_VALUE() load_value<int>()

int macro_and_alias_boundary() {
  ValuePointer value = LOAD_VALUE();
  return *value;
}

int *load_value(int);
int *load_value(double);

int overload_boundary() {
  auto value = load_value(1);
  return *value;
}
