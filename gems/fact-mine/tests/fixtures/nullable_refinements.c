#include <stddef.h>

int read_or_default(int *value) {
    if (value == NULL) {
        return 0;
    }
    return *value;
}

int write_when_missing(int *value) {
    if (value != NULL) {
        return *value;
    }
    return 0;
}
