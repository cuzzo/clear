/*
 * Footgun: Iterator Invalidation — C
 *
 * C has no iterator abstraction — you iterate using pointers or indices.
 * Modifying a collection while iterating via a pointer is undefined behavior
 * if it causes reallocation (e.g., via realloc). Even without reallocation,
 * inserting or removing elements shifts the indices, making pointer-based
 * iteration produce wrong results or skip/repeat elements.
 *
 * Linked list traversal while removing nodes is a classic case: if you free
 * the current node before advancing the pointer, the "next" read is a
 * use-after-free.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* BROKEN: grow a dynamic array while iterating over it.
 * realloc may move the array; the pointer p stored before realloc is
 * now a dangling pointer. */
void realloc_during_iter(void) {
    int *arr = malloc(4 * sizeof(int));
    for (int i = 0; i < 4; i++) arr[i] = i;

    int *p = arr; /* pointer into the array */
    int n = 4;
    for (int i = 0; i < n; i++) {
        printf("arr[%d] = %d\n", i, p[i]);
        /* BROKEN: realloc may move the allocation; p is now dangling */
        arr = realloc(arr, (n + 1) * sizeof(int));
        arr[n] = n;
        n++;
        /* p still points to old memory — UB on next iteration */
        if (n > 6) break; /* prevent infinite loop */
    }
    free(arr);
}

/* BROKEN: remove a node from a linked list using the current pointer.
 * After free(cur), accessing cur->next is use-after-free. */
typedef struct Node { int val; struct Node *next; } Node;

void linked_list_uaf(void) {
    Node *head = NULL;
    for (int i = 3; i >= 0; i--) {
        Node *n = malloc(sizeof(Node));
        n->val = i; n->next = head; head = n;
    }

    Node *cur = head;
    while (cur != NULL) {
        printf("val = %d\n", cur->val);
        Node *next = cur->next; /* save next BEFORE free */
        /* BROKEN: if you do free(cur) then access cur->next, it's UAF */
        /* free(cur); cur = cur->next; -- classic bug */
        free(cur);              /* correct: free after saving next */
        cur = next;
    }
}

/* BROKEN: skip elements when removing via index during iteration.
 * After removing index i, element i+1 shifts to index i — the loop's
 * i++ skips it. */
void index_skip(void) {
    int arr[] = {1, 2, 3, 4, 5};
    int n = 5;
    for (int i = 0; i < n; i++) {
        if (arr[i] % 2 == 0) {
            /* shift elements left */
            memmove(&arr[i], &arr[i+1], (n - i - 1) * sizeof(int));
            n--;
            /* BUG: i is incremented next iteration, skipping arr[i] */
            /* Fix: i-- here to re-examine the element that shifted in */
        }
    }
    for (int i = 0; i < n; i++) printf("%d ", arr[i]);
    printf("\n"); /* prints: 1 3 5 (correct) or 1 3 4 5 (skipped 3) */
}

int main(void) {
    printf("--- index skip during removal ---\n");
    index_skip();

    printf("--- linked list traversal ---\n");
    linked_list_uaf();

    return 0;
}
