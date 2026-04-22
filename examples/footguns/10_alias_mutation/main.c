/*
 * Footgun: Alias Mutation — C
 *
 * In C, any two pointers of the same (or compatible) type can alias the
 * same memory. Mutating memory through one pointer while another pointer
 * holds a "view" of that memory produces unexpected results. The compiler
 * may also misoptimize: if it assumes two pointers don't alias (strict
 * aliasing rule), it may cache a value in a register and never re-read
 * the memory that was modified through the other pointer.
 *
 * The `restrict` keyword promises the compiler two pointers don't alias,
 * enabling optimization — but C does not enforce this promise. Lying with
 * `restrict` is undefined behavior that the compiler may silently exploit.
 */

#include <stdio.h>
#include <stdlib.h>

/* BROKEN: caller passes the same array for both src and dst.
 * memmove handles overlap; memcpy does not. If you call this with
 * aliasing pointers the behavior is undefined for overlapping ranges. */
void unsafe_copy(int *dst, const int *src, int n) {
    for (int i = 0; i < n; i++) {
        dst[i] = src[i]; /* if dst == src or overlaps, this is a data race
                          * between the write on this iteration and a future
                          * read — behavior depends on the overlap direction */
    }
}

/* BROKEN: two pointers into the same array. Modifying via p while
 * reading via q produces surprising output. */
void aliased_pointers(void) {
    int arr[4] = {1, 2, 3, 4};
    int *p = &arr[0]; /* points to arr[0] */
    int *q = &arr[0]; /* also points to arr[0] — same memory! */

    *p = 99;
    printf("*q after *p = 99: %d\n", *q); /* reads 99, not 1 */
    /* A caller who passed q expecting the original value gets a surprise. */
}

/* BROKEN: restrict lie. The compiler may cache src[0] in a register
 * and use it for all iterations, never re-reading after dst modified it.
 * On optimized builds this can produce wrong output. */
void restrict_lie(int * restrict dst, const int * restrict src, int n) {
    /* Caller passes dst == src — violates restrict, UB on -O2 */
    for (int i = 0; i < n; i++) {
        dst[i] = src[i] + 1;
    }
}

int main(void) {
    printf("--- aliased pointers ---\n");
    aliased_pointers();

    printf("--- restrict lie ---\n");
    int arr[4] = {1, 2, 3, 4};
    restrict_lie(arr, arr, 4); /* lie: dst == src */
    for (int i = 0; i < 4; i++) printf("%d ", arr[i]);
    printf("\n");

    return 0;
}

/*
 * Fix: use __restrict__ annotations correctly (and don't lie), or copy
 * src to a local buffer before writing dst, or use memmove for overlapping
 * copies. In practice, aliasing bugs are caught by -fsanitize=undefined
 * (strict-aliasing violations) or by careful code review.
 */
