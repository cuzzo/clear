#include <new>

struct Base { virtual ~Base() = default; };
struct Derived : Base { int field; };

int dereference_nothrow() {
  int *value = new (std::nothrow) int;
  return *value;
}

int dereference_dynamic_cast(Base *value) {
  Derived *cast = dynamic_cast<Derived *>(value);
  return cast->field;
}

int dereference_throwing_new() {
  int *value = new int;
  return *value;
}
