#include <string>

bool contains(const std::string & text, const std::string & needle) {
  return text.find(needle) != std::string::npos;
}
