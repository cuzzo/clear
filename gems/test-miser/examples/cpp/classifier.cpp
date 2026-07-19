#include "classifier.hpp"

const char *classify(int value) {
  if (value > 10) return "high";
  if (value > 0) return "positive";
  return "nonpositive";
}
