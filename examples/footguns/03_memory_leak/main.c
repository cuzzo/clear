/*
 * Footgun: Memory Leak — C
 *
 * An early-return on the error path skips the free(). The allocation
 * is reachable nowhere after the function returns, but it is never
 * freed. C has no destructors, no defer, no static analysis built in.
 * The leak is silent unless you run valgrind or ASan.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define BUFSIZE 256

/* Returns a heap-allocated processed string, or NULL on error.
 * BUG: the buf allocation is leaked when input starts with '!'. */
char *process(const char *input) {
    char *buf = malloc(BUFSIZE);
    if (!buf) return NULL;

    snprintf(buf, BUFSIZE, "processed: %s", input);

    if (input[0] == '!') {
        /* Error path: forgot to free(buf) before returning NULL. */
        return NULL; /* leak: buf is gone, never freed */
    }

    return buf; /* caller must free this */
}

int main(void) {
    /* Happy path: result is freed correctly. */
    char *r1 = process("hello");
    if (r1) { printf("%s\n", r1); free(r1); }

    /* Error path: buf inside process() is leaked silently. */
    char *r2 = process("!bad");
    if (!r2) printf("error (and a leak just happened)\n");

    return 0;
}

/*
 * Compile and run:
 *   gcc -o leak main.c && ./leak
 *   valgrind --leak-check=full ./leak
 *   gcc -fsanitize=address -o leak main.c && ./leak
 *
 * Result without tools: silent leak.
 * Result with valgrind/ASan: "definitely lost: 256 bytes in 1 block"
 */
