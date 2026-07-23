#include <cstddef>

std::size_t cpp_unevaluated_expressions_are_safe() {
  int *value = nullptr;
  return sizeof(*value) + alignof(*value) + sizeof(decltype(*value)) + noexcept(*value);
}

int cpp_evaluated_dereference_is_reported() {
  int *value = nullptr;
  return *value;
}
