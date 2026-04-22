/*
 * Footgun: Buffer Overflow — C
 *
 * C has no bounds checking on arrays or pointer arithmetic. Writing past
 * the end of a buffer is undefined behavior: it silently corrupts adjacent
 * memory, overwrites return addresses (stack smashing), or corrupts heap
 * metadata. The program may appear to work on one platform and crash or
 * produce wrong results on another.
 *
 * Neither the compiler nor the runtime detects this by default. You must
 * opt in to AddressSanitizer (-fsanitize=address) or Valgrind to catch it.
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

/* BROKEN: write 10 bytes into a 4-byte stack buffer. On x86-64 this
 * typically corrupts the saved frame pointer and/or return address.
 * The behavior is undefined — crash, silent wrong output, or "works". */
void stack_overflow(void) {
    char buf[4];
    /* strncpy does NOT null-terminate if src >= n; memcpy has no bounds at all */
    memcpy(buf, "0123456789", 10); /* writes 6 bytes past end of buf */
    printf("stack buf: %.4s\n", buf);
}

/* BROKEN: write past end of a heap allocation. Corrupts malloc metadata
 * or adjacent heap objects. May not crash immediately; failure is delayed
 * until the corrupted allocation is freed or reused. */
void heap_overflow(void) {
    char *p = malloc(4);
    if (!p) return;
    memcpy(p, "0123456789", 10); /* 6 bytes past end of p */
    printf("heap buf: %.4s\n", p);
    free(p); /* may crash here due to corrupted heap metadata */
}

/* BROKEN: off-by-one index into a stack array. Classic fencepost error.
 * arr[8] is one past the end of an 8-element array (valid indices: 0-7). */
void off_by_one(void) {
    int arr[8] = {0};
    for (int i = 0; i <= 8; i++) { /* should be i < 8 */
        arr[i] = i;                 /* arr[8] writes past end */
    }
    printf("arr[7]=%d\n", arr[7]);
}

int main(void) {
    printf("--- stack overflow ---\n");
    stack_overflow();

    printf("--- heap overflow ---\n");
    heap_overflow();

    printf("--- off-by-one ---\n");
    off_by_one();

    return 0;
}

/*
 * Compile to see the overflow in action:
 *   gcc -o buf_c main.c && ./buf_c          # may "work" — UB
 *   gcc -fsanitize=address -o buf_c main.c && ./buf_c  # ASan catches it
 *
 * Fix: use strnlen + size-bounded copies; validate indices before access;
 * or switch to a language with bounds checking.
 */
