#include <string.h>

int inspect(const char *text, const char *needle) {
  return (int)strlen(text) + strcmp(text, needle);
}
