/*
 * Puck V10 — C interpreter for the Puck bytecode that V9's Ruby pipeline
 * produces. Same value model (integers + refcounted heap arrays), same
 * opcodes, same procedure-table CALL convention.
 *
 * The whole point of V10 is that this file does exactly what V9's vm.rb
 * does, just in C. The bytecode it consumes is unchanged.
 *
 * Build:  make vm
 * Run:    ./vm program.puckc
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <ctype.h>

/* ===========================================================================
 * Value, heap, opcodes.
 * ========================================================================= */

typedef enum {
    V_INT, V_FLOAT, V_REF
} ValueTag;

typedef struct {
    ValueTag tag;
    union {
        int64_t i;    /* V_INT: integer value. V_REF: heap index. */
        double  f;    /* V_FLOAT: 64-bit float. */
    };
} Value;

typedef struct {
    int32_t  refs;
    int32_t  length;
    Value*   cells;
} HeapEntry;

typedef enum {
    OP_PUSH, OP_PUSH_FLOAT, OP_ALLOC, OP_ALLOC_CELL, OP_ALLOC_ARRAY,
    OP_LOAD, OP_LOAD_REF, OP_ARRAY_LEN,
    OP_STORE, OP_STORE_REF, OP_ARRAY_GET, OP_ARRAY_SET,
    OP_MATH, OP_COMPARE,
    OP_JUMP, OP_JUMP_IF_FALSE,
    OP_CALL, OP_RETURN, OP_SYSCALL,
    OP_INVALID
} Op;

/* Math/compare operators are kept as small enum codes — the bytecode embeds
 * them in the ByteCode.kind field, and the VM dispatches via switch. */
typedef enum {
    K_ADD, K_SUB, K_MUL, K_DIV, K_MOD,
    K_EQ, K_NEQ, K_LT, K_LE, K_GT, K_GE,
    K_NONE
} OpKind;

typedef struct {
    Op op;
    /* PUSH_FLOAT puts its literal in `arg_f`; everything else uses `arg`. */
    union {
        int32_t arg;
        double  arg_f;
    };
    OpKind kind;  /* Only used by MATH/COMPARE. */
} ByteCode;

typedef struct {
    int32_t   params;
    int32_t   var_params;
    int32_t   codes_len;
    ByteCode* codes;
} Procedure;

typedef struct {
    /* String literals interned by the serializer. ALLOC's arg is an index. */
    char**     strings;
    int32_t    strings_len;

    /* Procedure table. CALL's arg is an index. Procedure 0 is `main`. */
    Procedure* procs;
    int32_t    procs_len;
} Program;

/* ===========================================================================
 * Heap. One growable array of HeapEntry. A freelist of released slot indices
 * is reused on the next allocation so heap.size doesn't grow unboundedly.
 * ========================================================================= */

static HeapEntry* heap = NULL;
static int32_t    heap_cap = 0;
static int32_t    heap_len = 0;

static int32_t*   freelist = NULL;
static int32_t    freelist_cap = 0;
static int32_t    freelist_len = 0;

/* Files opened by SYSCALL 3 — handle is the index into this table. */
static FILE**     files = NULL;
static int32_t    files_cap = 0;
static int32_t    files_len = 0;

static int32_t heap_alloc(Value* cells, int32_t length) {
    int32_t id;
    if (freelist_len > 0) {
        id = freelist[--freelist_len];
    } else {
        if (heap_len == heap_cap) {
            heap_cap = heap_cap ? heap_cap * 2 : 64;
            heap = realloc(heap, sizeof(HeapEntry) * heap_cap);
        }
        id = heap_len++;
    }
    heap[id].refs   = 1;
    heap[id].length = length;
    heap[id].cells  = cells;
    return id;
}

static void heap_free_slot(int32_t id) {
    if (freelist_len == freelist_cap) {
        freelist_cap = freelist_cap ? freelist_cap * 2 : 64;
        freelist = realloc(freelist, sizeof(int32_t) * freelist_cap);
    }
    freelist[freelist_len++] = id;
}

/* Forward declarations — release recurses through nested refs. */
static Value retain(Value v);
static void  release(Value v);

static Value retain(Value v) {
    if (v.tag == V_REF) heap[v.i].refs++;
    return v;
}

static void release(Value v) {
    if (v.tag != V_REF) return;
    HeapEntry* h = &heap[v.i];
    if (--h->refs > 0) return;
    /* Refs hit zero — release any nested refs, then free. */
    for (int32_t i = 0; i < h->length; i++) release(h->cells[i]);
    free(h->cells);
    h->cells = NULL;
    h->length = 0;
    heap_free_slot((int32_t)v.i);
}

/* ===========================================================================
 * Allocators that produce a Value (V_REF tagged).
 * ========================================================================= */

static Value alloc_codepoints(const char* str) {
    int32_t n = (int32_t)strlen(str);
    Value*  cells = malloc(sizeof(Value) * (n > 0 ? n : 1));
    for (int32_t i = 0; i < n; i++) {
        cells[i].tag = V_INT;
        cells[i].i = (unsigned char)str[i];
    }
    int32_t id = heap_alloc(cells, n);
    Value v = { V_REF, { .i = id } };
    return v;
}

static Value alloc_cells(int32_t length, Value init) {
    Value* cells = malloc(sizeof(Value) * (length > 0 ? length : 1));
    for (int32_t i = 0; i < length; i++) cells[i] = init;
    int32_t id = heap_alloc(cells, length);
    Value v = { V_REF, { .i = id } };
    return v;
}

/* ===========================================================================
 * Bytecode file loader. Plain text, one op per line.
 * ========================================================================= */

static char* read_line(FILE* f) {
    static char buf[8192];
    if (!fgets(buf, sizeof buf, f)) return NULL;
    size_t n = strlen(buf);
    if (n > 0 && buf[n - 1] == '\n') buf[n - 1] = '\0';
    return buf;
}

static Op parse_op_name(const char* s) {
    if (!strcmp(s, "PUSH"))          return OP_PUSH;
    if (!strcmp(s, "PUSH_FLOAT"))    return OP_PUSH_FLOAT;
    if (!strcmp(s, "ALLOC"))         return OP_ALLOC;
    if (!strcmp(s, "ALLOC_CELL"))    return OP_ALLOC_CELL;
    if (!strcmp(s, "ALLOC_ARRAY"))   return OP_ALLOC_ARRAY;
    if (!strcmp(s, "LOAD"))          return OP_LOAD;
    if (!strcmp(s, "LOAD_REF"))      return OP_LOAD_REF;
    if (!strcmp(s, "ARRAY_LEN"))     return OP_ARRAY_LEN;
    if (!strcmp(s, "STORE"))         return OP_STORE;
    if (!strcmp(s, "STORE_REF"))     return OP_STORE_REF;
    if (!strcmp(s, "ARRAY_GET"))     return OP_ARRAY_GET;
    if (!strcmp(s, "ARRAY_SET"))     return OP_ARRAY_SET;
    if (!strcmp(s, "MATH"))          return OP_MATH;
    if (!strcmp(s, "COMPARE"))       return OP_COMPARE;
    if (!strcmp(s, "JUMP"))          return OP_JUMP;
    if (!strcmp(s, "JUMP_IF_FALSE")) return OP_JUMP_IF_FALSE;
    if (!strcmp(s, "CALL"))          return OP_CALL;
    if (!strcmp(s, "RETURN"))        return OP_RETURN;
    if (!strcmp(s, "SYSCALL"))       return OP_SYSCALL;
    return OP_INVALID;
}

static OpKind parse_kind(const char* s) {
    /* Math operators from Ruby's symbol form: +, -, *, /, %. */
    if (!strcmp(s, "+")) return K_ADD;
    if (!strcmp(s, "-")) return K_SUB;
    if (!strcmp(s, "*")) return K_MUL;
    if (!strcmp(s, "/")) return K_DIV;
    if (!strcmp(s, "%")) return K_MOD;
    /* Compare operators: Ruby method names (==, !=, <, <=, >, >=). */
    if (!strcmp(s, "==")) return K_EQ;
    if (!strcmp(s, "!=")) return K_NEQ;
    if (!strcmp(s, "<"))  return K_LT;
    if (!strcmp(s, "<=")) return K_LE;
    if (!strcmp(s, ">"))  return K_GT;
    if (!strcmp(s, ">=")) return K_GE;
    return K_NONE;
}

static Program* load_program(const char* path) {
    FILE* f = fopen(path, "r");
    if (!f) { perror(path); exit(1); }

    char* line;
    if ((line = read_line(f)) == NULL || strcmp(line, "PUCKC 1") != 0) {
        fprintf(stderr, "bad header: %s\n", line ? line : "(EOF)");
        exit(1);
    }

    Program* p = calloc(1, sizeof(Program));

    /* STRINGS section */
    line = read_line(f);
    sscanf(line, "STRINGS %d", &p->strings_len);
    p->strings = calloc(p->strings_len, sizeof(char*));
    for (int32_t i = 0; i < p->strings_len; i++) {
        line = read_line(f);
        p->strings[i] = strdup(line ? line : "");
    }

    /* PROCS section */
    line = read_line(f);
    sscanf(line, "PROCS %d", &p->procs_len);
    p->procs = calloc(p->procs_len, sizeof(Procedure));

    for (int32_t i = 0; i < p->procs_len; i++) {
        line = read_line(f);
        int params, var_params, codes_len;
        sscanf(line, "PROC %d %d %d", &params, &var_params, &codes_len);
        p->procs[i].params     = params;
        p->procs[i].var_params = var_params;
        p->procs[i].codes_len  = codes_len;
        p->procs[i].codes      = calloc(codes_len, sizeof(ByteCode));

        for (int32_t j = 0; j < codes_len; j++) {
            line = read_line(f);
            char op_buf[32], arg_buf[64];
            int n = sscanf(line, "%31s %63s", op_buf, arg_buf);
            ByteCode* c = &p->procs[i].codes[j];
            c->op = parse_op_name(op_buf);
            c->kind = K_NONE;
            if (n == 2) {
                if (c->op == OP_MATH || c->op == OP_COMPARE) {
                    c->kind = parse_kind(arg_buf);
                } else if (c->op == OP_PUSH_FLOAT) {
                    c->arg_f = strtod(arg_buf, NULL);
                } else {
                    c->arg = (int32_t)strtol(arg_buf, NULL, 10);
                }
            }
        }
    }

    fclose(f);
    return p;
}

/* ===========================================================================
 * VM execution. Mirrors examples/puck/v9/vm.rb#run_codes one-to-one. The
 * memory is a fixed-size frame (256 slots is plenty for V10 programs).
 * ========================================================================= */

#define MAX_SLOTS 256
#define MAX_STACK 4096

static Program* program;

static int64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void print_value(Value v) {
    if (v.tag == V_INT) {
        printf("%lld", (long long)v.i);
        return;
    }
    if (v.tag == V_FLOAT) {
        printf("%g", v.f);
        return;
    }
    /* V_REF: render the heap payload as a string (codepoint array). */
    HeapEntry* h = &heap[v.i];
    for (int32_t i = 0; i < h->length; i++) {
        putchar((int)h->cells[i].i);
    }
}

static Value handle_syscall(Value* stack, int32_t* sp, int32_t id);

static Value run_codes(ByteCode* codes, int32_t codes_len, Value* memory) {
    Value stack[MAX_STACK];
    int32_t sp = 0;
    int32_t ip = 0;
    Value result = { V_INT, { .i = 0 } };

    while (ip < codes_len) {
        ByteCode* c = &codes[ip++];
        switch (c->op) {
            case OP_PUSH: {
                Value v = { V_INT, { .i = c->arg } };
                stack[sp++] = v;
                break;
            }
            case OP_PUSH_FLOAT: {
                Value v = { V_FLOAT, { .f = c->arg_f } };
                stack[sp++] = v;
                break;
            }
            case OP_ALLOC:
                stack[sp++] = alloc_codepoints(program->strings[c->arg]);
                break;
            case OP_ALLOC_CELL: {
                Value v = stack[--sp];
                Value* cells = malloc(sizeof(Value));
                cells[0] = v;
                int32_t id = heap_alloc(cells, 1);
                Value r = { V_REF, { .i = id } };
                stack[sp++] = r;
                break;
            }
            case OP_ALLOC_ARRAY: {
                int32_t size = (int32_t)stack[--sp].i;
                Value zero = { V_INT, { .i = 0 } };
                stack[sp++] = alloc_cells(size, zero);
                break;
            }
            case OP_LOAD:
                stack[sp++] = retain(memory[c->arg]);
                break;
            case OP_LOAD_REF: {
                Value ref = memory[c->arg];
                stack[sp++] = retain(heap[ref.i].cells[0]);
                break;
            }
            case OP_ARRAY_LEN: {
                Value ref = stack[--sp];
                Value len = { V_INT, { .i = heap[ref.i].length } };
                stack[sp++] = len;
                release(ref);
                break;
            }
            case OP_STORE:
                release(memory[c->arg]);
                memory[c->arg] = stack[--sp];
                break;
            case OP_STORE_REF: {
                Value new_value = stack[--sp];
                Value ref = memory[c->arg];
                release(heap[ref.i].cells[0]);
                heap[ref.i].cells[0] = new_value;
                break;
            }
            case OP_ARRAY_GET: {
                int32_t index = (int32_t)stack[--sp].i;
                Value ref = stack[--sp];
                stack[sp++] = retain(heap[ref.i].cells[index]);
                release(ref);
                break;
            }
            case OP_ARRAY_SET: {
                Value value = stack[--sp];
                int32_t index = (int32_t)stack[--sp].i;
                Value ref = stack[--sp];
                release(heap[ref.i].cells[index]);
                heap[ref.i].cells[index] = value;
                release(ref);
                break;
            }
            case OP_MATH: {
                Value right = stack[--sp];
                Value left  = stack[--sp];
                Value v;
                if (left.tag == V_FLOAT || right.tag == V_FLOAT) {
                    double a = (left.tag == V_FLOAT)  ? left.f  : (double)left.i;
                    double b = (right.tag == V_FLOAT) ? right.f : (double)right.i;
                    v.tag = V_FLOAT;
                    switch (c->kind) {
                        case K_ADD: v.f = a + b; break;
                        case K_SUB: v.f = a - b; break;
                        case K_MUL: v.f = a * b; break;
                        case K_DIV: v.f = a / b; break;
                        case K_MOD: v.f = a - b * (int64_t)(a / b); break;
                        default: fprintf(stderr, "bad MATH kind\n"); exit(1);
                    }
                } else {
                    v.tag = V_INT;
                    switch (c->kind) {
                        case K_ADD: v.i = left.i + right.i; break;
                        case K_SUB: v.i = left.i - right.i; break;
                        case K_MUL: v.i = left.i * right.i; break;
                        case K_DIV: v.i = left.i / right.i; break;
                        case K_MOD: v.i = left.i % right.i; break;
                        default: fprintf(stderr, "bad MATH kind\n"); exit(1);
                    }
                }
                stack[sp++] = v;
                break;
            }
            case OP_COMPARE: {
                Value right = stack[--sp];
                Value left  = stack[--sp];
                int64_t r;
                if (left.tag == V_FLOAT || right.tag == V_FLOAT) {
                    double a = (left.tag == V_FLOAT)  ? left.f  : (double)left.i;
                    double b = (right.tag == V_FLOAT) ? right.f : (double)right.i;
                    switch (c->kind) {
                        case K_EQ:  r = (a == b); break;
                        case K_NEQ: r = (a != b); break;
                        case K_LT:  r = (a <  b); break;
                        case K_LE:  r = (a <= b); break;
                        case K_GT:  r = (a >  b); break;
                        case K_GE:  r = (a >= b); break;
                        default: fprintf(stderr, "bad COMPARE kind\n"); exit(1);
                    }
                } else {
                    switch (c->kind) {
                        case K_EQ:  r = (left.i == right.i); break;
                        case K_NEQ: r = (left.i != right.i); break;
                        case K_LT:  r = (left.i <  right.i); break;
                        case K_LE:  r = (left.i <= right.i); break;
                        case K_GT:  r = (left.i >  right.i); break;
                        case K_GE:  r = (left.i >= right.i); break;
                        default: fprintf(stderr, "bad COMPARE kind\n"); exit(1);
                    }
                }
                Value v = { V_INT, { .i = r } };
                stack[sp++] = v;
                break;
            }
            case OP_JUMP:
                ip = c->arg;
                break;
            case OP_JUMP_IF_FALSE: {
                Value cond = stack[--sp];
                if (cond.i == 0) ip = c->arg;
                break;
            }
            case OP_CALL: {
                Procedure* callee = &program->procs[c->arg];
                Value callee_mem[MAX_SLOTS] = {{ V_INT, { .i = 0 } }};
                /* Pop callee->params args off our stack in order. */
                for (int32_t i = callee->params - 1; i >= 0; i--) {
                    callee_mem[i] = stack[--sp];
                }
                Value res = run_codes(callee->codes, callee->codes_len, callee_mem);
                if (res.tag != V_INT || res.i != INT64_MIN) {
                    /* Convention: an explicit RETURN value gets pushed; an
                     * implicit run-off-the-end is signalled by returning
                     * { V_INT, { .i = INT64_MIN } } below, which we drop here. */
                    stack[sp++] = res;
                }
                break;
            }
            case OP_RETURN:
                result = stack[--sp];
                for (int32_t i = 0; i < MAX_SLOTS; i++) release(memory[i]);
                return result;
            case OP_SYSCALL:
                handle_syscall(stack, &sp, c->arg);
                break;
            case OP_INVALID:
                fprintf(stderr, "invalid op\n");
                exit(1);
        }
    }

    /* Ran off the end — cleanup memory and signal "no return value". */
    for (int32_t i = 0; i < MAX_SLOTS; i++) release(memory[i]);
    Value none = { V_INT, { .i = INT64_MIN } };
    return none;
}

static Value handle_syscall(Value* stack, int32_t* sp, int32_t id) {
    switch (id) {
        case 1: {
            Value v = stack[--(*sp)];
            printf("OUTPUT: ");
            print_value(v);
            putchar('\n');
            release(v);
            break;
        }
        case 2: {
            char buf[8192];
            if (fgets(buf, sizeof buf, stdin)) {
                size_t n = strlen(buf);
                if (n > 0 && buf[n - 1] == '\n') buf[n - 1] = '\0';
                stack[(*sp)++] = alloc_codepoints(buf);
            } else {
                stack[(*sp)++] = alloc_codepoints("");
            }
            break;
        }
        case 3: {
            Value name = stack[--(*sp)];
            HeapEntry* h = &heap[name.i];
            char path[1024];
            int32_t i;
            for (i = 0; i < h->length && i < (int32_t)sizeof(path) - 1; i++) {
                path[i] = (char)h->cells[i].i;
            }
            path[i] = '\0';
            if (files_len == files_cap) {
                files_cap = files_cap ? files_cap * 2 : 8;
                files = realloc(files, sizeof(FILE*) * files_cap);
            }
            files[files_len] = fopen(path, "r");
            Value handle = { V_INT, { .i = files_len++ } };
            stack[(*sp)++] = handle;
            release(name);
            break;
        }
        case 4: {
            int32_t handle = (int32_t)stack[--(*sp)].i;
            char buf[8192];
            if (fgets(buf, sizeof buf, files[handle])) {
                size_t n = strlen(buf);
                if (n > 0 && buf[n - 1] == '\n') buf[n - 1] = '\0';
                stack[(*sp)++] = alloc_codepoints(buf);
            } else {
                Value zero = { V_INT, { .i = 0 } };
                stack[(*sp)++] = zero;
            }
            break;
        }
        case 5: {
            int32_t handle = (int32_t)stack[--(*sp)].i;
            fclose(files[handle]);
            break;
        }
        case 6: {
            Value t = { V_INT, { .i = now_ms() } };
            stack[(*sp)++] = t;
            break;
        }
        case 7: {
            /* open for write — path string on stack, push integer handle. */
            Value name = stack[--(*sp)];
            HeapEntry* h = &heap[name.i];
            char path[1024];
            int32_t i;
            for (i = 0; i < h->length && i < (int32_t)sizeof(path) - 1; i++) {
                path[i] = (char)h->cells[i].i;
            }
            path[i] = '\0';
            if (files_len == files_cap) {
                files_cap = files_cap ? files_cap * 2 : 8;
                files = realloc(files, sizeof(FILE*) * files_cap);
            }
            files[files_len] = fopen(path, "w");
            Value handle = { V_INT, { .i = files_len++ } };
            stack[(*sp)++] = handle;
            release(name);
            break;
        }
        case 8: {
            /* write a string + newline to an open file. handle then string on stack. */
            Value string = stack[--(*sp)];
            int32_t handle = (int32_t)stack[--(*sp)].i;
            HeapEntry* h = &heap[string.i];
            for (int32_t i = 0; i < h->length; i++) {
                fputc((int)h->cells[i].i, files[handle]);
            }
            fputc('\n', files[handle]);
            release(string);
            break;
        }
        default:
            fprintf(stderr, "unknown SYSCALL id %d\n", id);
            exit(1);
    }
    Value none = { V_INT, { .i = 0 } };
    return none;
}

int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s program.puckc\n", argv[0]);
        return 1;
    }
    program = load_program(argv[1]);
    Procedure* main_proc = &program->procs[0];
    Value main_mem[MAX_SLOTS] = {{ V_INT, { .i = 0 } }};
    run_codes(main_proc->codes, main_proc->codes_len, main_mem);
    return 0;
}
