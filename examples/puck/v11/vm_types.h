/* Shared types between vm.c and jit.c. v10 keeps these inside vm.c;
   v11 lifts them so the JIT pass can see Procedure / ByteCode without
   pulling in the whole VM. */

#ifndef PUCK_V11_VM_TYPES_H
#define PUCK_V11_VM_TYPES_H

#include <stddef.h>
#include <stdint.h>

typedef enum { V_INT, V_FLOAT, V_REF } ValueTag;

typedef struct {
    ValueTag tag;
    union {
        int64_t i;
        double  f;
    };
} Value;

typedef enum {
    OP_PUSH, OP_PUSH_FLOAT, OP_ALLOC, OP_ALLOC_CELL, OP_ALLOC_ARRAY,
    OP_LOAD, OP_LOAD_REF, OP_ARRAY_LEN,
    OP_STORE, OP_STORE_REF, OP_ARRAY_GET, OP_ARRAY_SET,
    OP_MATH, OP_COMPARE,
    OP_JUMP, OP_JUMP_IF_FALSE,
    OP_CALL, OP_RETURN, OP_SYSCALL,
    OP_INVALID
} Op;

typedef enum {
    K_ADD, K_SUB, K_MUL, K_DIV, K_MOD,
    K_EQ, K_NEQ, K_LT, K_LE, K_GT, K_GE,
    K_NONE
} OpKind;

typedef struct {
    Op op;
    union {
        int32_t arg;
        double  arg_f;
    };
    OpKind kind;
} ByteCode;

typedef struct {
    int32_t   params;
    int32_t   var_params;
    int32_t   codes_len;
    ByteCode* codes;

    /* v11 additions. NULL jit_fn = "this proc is not JITed; interpret it".
       jit_code is the mmap'd page base; we keep it so a future cleanup
       pass could munmap. jit_size is the page size we asked for. */
    void*     jit_fn;
    uint8_t*  jit_code;
    size_t    jit_size;
} Procedure;

typedef struct {
    char**     strings;
    int32_t    strings_len;
    Procedure* procs;
    int32_t    procs_len;
} Program;

#endif
