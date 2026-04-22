/*
 * Footgun: Uninitialized Read — C
 *
 * In C, local variables are not zero-initialized unless you explicitly
 * assign them. Reading an uninitialized variable is undefined behavior:
 * on a real program the "garbage" value comes from whatever was on the
 * stack in a previous call frame. Compilers may or may not warn; -Wall
 * catches simple cases but misses many real-world patterns.
 *
 * This bug is subtle because:
 * - It passes compilation without -Wall or with ignored warnings
 * - It often "works" in debug builds (debug allocators zero memory)
 * - It fails intermittently in release builds when the stack pattern changes
 * - Valgrind / MSan (-fsanitize=memory) can detect it; nothing else can
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

/* BROKEN: x is never assigned but is used. On most real programs this
 * reads the garbage left by a previous function's stack frame. */
void uninitialized_local(void) {
    int x; /* declared but never assigned */
    /* gcc -Wall: "warning: 'x' is used uninitialized" — often ignored */
    printf("x = %d\n", x); /* UB: any value, including 0 by accident */
}

/* BROKEN: conditional initialization — only one branch assigns sum.
 * If n == 0 the else branch doesn't run, so sum is unread garbage. */
int conditional_init(int n) {
    int sum;
    if (n > 0) {
        sum = 0;
        for (int i = 0; i < n; i++) sum += i;
    }
    /* when n <= 0, sum is never assigned */
    return sum; /* UB when n <= 0 */
}

/* BROKEN: struct field not initialized — the other fields of the struct
 * are left as whatever bytes were on the stack. Happens frequently when
 * new fields are added to a struct and old initialization code is not
 * updated. */
typedef struct { int a; int b; int c; } Triple;

Triple uninitialized_struct(void) {
    Triple t;
    t.a = 1;
    t.b = 2;
    /* t.c is never assigned */
    return t; /* t.c is garbage */
}

int main(void) {
    printf("--- uninitialized local ---\n");
    uninitialized_local();

    printf("--- conditional init (n=0) ---\n");
    printf("sum = %d\n", conditional_init(0)); /* UB */

    printf("--- uninitialized struct field ---\n");
    Triple t = uninitialized_struct();
    printf("t = {%d, %d, %d}\n", t.a, t.b, t.c); /* t.c is garbage */

    return 0;
}

/*
 * Detect: gcc -fsanitize=memory, Valgrind --track-origins=yes
 * Fix: always initialize at declaration:
 *   int x = 0;
 *   Triple t = {0};       -- zero-initializes all fields
 *   Triple t = {1, 2, 3}; -- explicit field values
 */
