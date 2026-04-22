/*
 * Footgun: Use-After-Free — C
 *
 * C gives you malloc/free and trusts you completely. Reading memory
 * after free is undefined behavior: it may return stale data, zeroed
 * data, or crash, depending on allocator state and optimization level.
 * No compiler error. No runtime error (usually). Silent corruption.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    char name[32];
    int  score;
} Player;

int main(void) {
    Player *p = malloc(sizeof(Player));
    strcpy(p->name, "Alice");
    p->score = 100;

    printf("before free: %s scored %d\n", p->name, p->score);

    free(p);

    /* UAF: p is freed but the pointer is still usable in C.
     * The allocator may have zeroed the memory, reused it, or left
     * it intact. All three outcomes are "undefined behavior". */
    printf("after free:  %s scored %d\n", p->name, p->score);

    /* Double-free: calling free() on the same pointer again is also
     * undefined behavior. On glibc this typically aborts with
     * "double free or corruption". */
    free(p);

    return 0;
}

/*
 * Compile and run:
 *   gcc -o uaf main.c && ./uaf
 *   gcc -fsanitize=address -o uaf main.c && ./uaf   # ASan catches it
 *
 * Result without sanitizers: silent wrong output or crash.
 * Result with ASan: ERROR: heap-use-after-free
 */
