/* v11 minimal JIT — x86_64 Linux emitter.

   What this file does, in one paragraph: walk every procedure in the
   program, decide which ones are pure-integer (no SYSCALL, no heap, no
   floats) AND only ever call other pure-integer procedures, then translate
   each surviving procedure's stack-machine bytecode into native x86_64 by
   emitting one fixed snippet per bytecode op. PUSH/LOAD/STORE talk to the
   x86 stack directly: the value stack IS the x86 stack, which is why the
   emitter is short. CALLs always go through `movabs rax, addr; call rax`
   with the absolute callee address patched in after every procedure has
   been emitted (so forward references resolve naturally).

   Why it's small:
   - Only one value tag (V_INT). No boxing, no tag checks, no GC.
   - One calling convention (System V AMD64). Args 0..5 live in
     rdi/rsi/rdx/rcx/r8/r9. Return in rax.
   - One memory layout. Locals at [rbp - (slot+1)*8]. Always disp32 so
     there's no short/long form branching.
   - One ISA. No #ifdef. Anything that's not x86_64 Linux short-circuits
     in jit_compile_program() and the interpreter handles every proc.

   Adding macOS Intel is a ~5-line change: define MAP_ANONYMOUS if missing
   and relax the #ifdef. Adding Windows x86_64 is ~10-15 lines: swap
   mmap/mprotect for VirtualAlloc/VirtualProtect and change the arg-reg
   list in the prologue spill (Windows uses rcx,rdx,r8,r9). Both are
   deliberately left out to keep the emitter a single ifdef-free walk. */

#include "jit.h"

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__x86_64__) && defined(__linux__)
#include <sys/mman.h>
#include <unistd.h>

/* ===========================================================================
 * Emit buffer + jump patch table for a single procedure.
 * ========================================================================= */

typedef struct {
    int32_t bc_target;   /* target bytecode index               */
    size_t  patch_at;    /* offset in code where rel32 lives    */
} JumpPatch;

typedef struct {
    uint8_t*    code;
    size_t      pos;
    size_t      cap;
    int32_t*    bc_to_code;     /* bytecode index -> code offset (set as we emit) */
    JumpPatch*  patches;
    int         patch_count;
    int         patch_cap;
} Emitter;

typedef struct {
    int    caller_idx;
    int    callee_idx;
    size_t imm64_offset;        /* offset within caller's code page */
} CrossCall;

/* ===========================================================================
 * Byte-level emit helpers. All ops go through emit_u8 so we never overflow
 * the page silently.
 * ========================================================================= */

static void emit_u8(Emitter* e, uint8_t b) {
    if (e->pos >= e->cap) {
        fprintf(stderr, "jit: code page overflow\n");
        exit(1);
    }
    e->code[e->pos++] = b;
}
static void emit_u32(Emitter* e, uint32_t v) {
    emit_u8(e, v        & 0xff);
    emit_u8(e, (v >> 8) & 0xff);
    emit_u8(e, (v >> 16)& 0xff);
    emit_u8(e, (v >> 24)& 0xff);
}
static void emit_u64(Emitter* e, uint64_t v) {
    emit_u32(e, (uint32_t)(v & 0xffffffff));
    emit_u32(e, (uint32_t)(v >> 32));
}
static void emit_u32_at(uint8_t* code, size_t off, uint32_t v) {
    code[off]     = v        & 0xff;
    code[off + 1] = (v >> 8) & 0xff;
    code[off + 2] = (v >> 16)& 0xff;
    code[off + 3] = (v >> 24)& 0xff;
}
static void emit_u64_at(uint8_t* code, size_t off, uint64_t v) {
    emit_u32_at(code, off, (uint32_t)(v & 0xffffffff));
    emit_u32_at(code, off + 4, (uint32_t)(v >> 32));
}

static void add_jump_patch(Emitter* e, int32_t bc_target, size_t patch_at) {
    if (e->patch_count == e->patch_cap) {
        e->patch_cap *= 2;
        e->patches = realloc(e->patches, sizeof(JumpPatch) * e->patch_cap);
    }
    e->patches[e->patch_count++] = (JumpPatch){ bc_target, patch_at };
}

/* ===========================================================================
 * Snippet emitters. One per bytecode op category. These are the entire JIT.
 * ========================================================================= */

/* mov rax, imm64; push rax  (10 + 1 = 11 bytes) */
static void emit_push_imm64(Emitter* e, int64_t v) {
    emit_u8(e, 0x48); emit_u8(e, 0xb8);          /* movabs rax, imm64 */
    emit_u64(e, (uint64_t)v);
    emit_u8(e, 0x50);                            /* push rax          */
}

/* push qword [rbp + disp32]  (6 bytes) */
static void emit_load_slot(Emitter* e, int32_t slot) {
    int32_t disp = -((slot + 1) * 8);
    emit_u8(e, 0xff); emit_u8(e, 0xb5);
    emit_u32(e, (uint32_t)disp);
}

/* pop qword [rbp + disp32]  (6 bytes) */
static void emit_store_slot(Emitter* e, int32_t slot) {
    int32_t disp = -((slot + 1) * 8);
    emit_u8(e, 0x8f); emit_u8(e, 0x85);
    emit_u32(e, (uint32_t)disp);
}

/* pop rcx; pop rax; <op rax, rcx>; push rax */
static void emit_math(Emitter* e, OpKind k) {
    emit_u8(e, 0x59);                            /* pop rcx */
    emit_u8(e, 0x58);                            /* pop rax */
    switch (k) {
        case K_ADD: emit_u8(e, 0x48); emit_u8(e, 0x01); emit_u8(e, 0xc8); break;
        case K_SUB: emit_u8(e, 0x48); emit_u8(e, 0x29); emit_u8(e, 0xc8); break;
        case K_MUL: emit_u8(e, 0x48); emit_u8(e, 0x0f); emit_u8(e, 0xaf); emit_u8(e, 0xc1); break;
        case K_DIV:
            emit_u8(e, 0x48); emit_u8(e, 0x99);              /* cqo            */
            emit_u8(e, 0x48); emit_u8(e, 0xf7); emit_u8(e, 0xf9); /* idiv rcx  */
            break;
        case K_MOD:
            emit_u8(e, 0x48); emit_u8(e, 0x99);              /* cqo            */
            emit_u8(e, 0x48); emit_u8(e, 0xf7); emit_u8(e, 0xf9); /* idiv rcx  */
            emit_u8(e, 0x48); emit_u8(e, 0x89); emit_u8(e, 0xd0); /* mov rax,rdx */
            break;
        default:
            fprintf(stderr, "jit: bad MATH kind %d\n", k);
            exit(1);
    }
    emit_u8(e, 0x50);                            /* push rax */
}

/* pop rcx; pop rax; cmp rax, rcx; setcc al; movzx rax, al; push rax */
static void emit_compare(Emitter* e, OpKind k) {
    emit_u8(e, 0x59);                                  /* pop rcx          */
    emit_u8(e, 0x58);                                  /* pop rax          */
    emit_u8(e, 0x48); emit_u8(e, 0x39); emit_u8(e, 0xc8); /* cmp rax, rcx  */
    uint8_t cc;
    switch (k) {
        case K_EQ:  cc = 0x94; break;
        case K_NEQ: cc = 0x95; break;
        case K_LT:  cc = 0x9c; break;
        case K_LE:  cc = 0x9e; break;
        case K_GT:  cc = 0x9f; break;
        case K_GE:  cc = 0x9d; break;
        default:
            fprintf(stderr, "jit: bad COMPARE kind %d\n", k);
            exit(1);
    }
    emit_u8(e, 0x0f); emit_u8(e, cc); emit_u8(e, 0xc0); /* setcc al        */
    emit_u8(e, 0x48); emit_u8(e, 0x0f);
    emit_u8(e, 0xb6); emit_u8(e, 0xc0);                /* movzx rax, al    */
    emit_u8(e, 0x50);                                  /* push rax         */
}

/* jmp rel32 (5 bytes; rel32 patched later) */
static void emit_jmp_placeholder(Emitter* e, int32_t bc_target) {
    emit_u8(e, 0xe9);
    add_jump_patch(e, bc_target, e->pos);
    emit_u32(e, 0);
}

/* pop rax; test rax, rax; jz rel32 (4 + 3 + 6 = 13 bytes) */
static void emit_jz_placeholder(Emitter* e, int32_t bc_target) {
    emit_u8(e, 0x58);                                  /* pop rax          */
    emit_u8(e, 0x48); emit_u8(e, 0x85); emit_u8(e, 0xc0); /* test rax, rax */
    emit_u8(e, 0x0f); emit_u8(e, 0x84);                /* jz rel32         */
    add_jump_patch(e, bc_target, e->pos);
    emit_u32(e, 0);
}

/* Pop N args off the value stack into the System V int-arg regs, then
   `movabs rax, addr; call rax; push rax`. addr is patched in after every
   proc is emitted. Param 0 ends up in rdi, param N-1 ends up on top of the
   stack (so we pop in reverse). */
static void emit_call_placeholder(Emitter* e, int callee_params, size_t* imm_at_out) {
    /* Each arg reg's `pop rN` encoding. Index = param position. */
    static const uint8_t pop_byte0[6] = { 0x5f, 0x5e, 0x5a, 0x59, 0x41, 0x41 };
    static const uint8_t pop_byte1[6] = { 0x00, 0x00, 0x00, 0x00, 0x58, 0x59 };
    for (int k = callee_params - 1; k >= 0; k--) {
        emit_u8(e, pop_byte0[k]);
        if (pop_byte1[k] != 0) emit_u8(e, pop_byte1[k]);
    }
    emit_u8(e, 0x48); emit_u8(e, 0xb8);                /* movabs rax, imm64 */
    *imm_at_out = e->pos;
    emit_u64(e, 0);
    emit_u8(e, 0xff); emit_u8(e, 0xd0);                /* call rax          */
    emit_u8(e, 0x50);                                  /* push rax          */
}

/* pop rax; leave; ret */
static void emit_return(Emitter* e) {
    emit_u8(e, 0x58);
    emit_u8(e, 0xc9);
    emit_u8(e, 0xc3);
}

/* Function prologue:
       push rbp
       mov  rbp, rsp
       sub  rsp, locals*8           (using disp32 form for uniformity)
       mov  [rbp + slot_i_disp], reg_i      for each param           */
static void emit_prologue(Emitter* e, int params, int locals) {
    emit_u8(e, 0x55);                                  /* push rbp         */
    emit_u8(e, 0x48); emit_u8(e, 0x89); emit_u8(e, 0xe5); /* mov rbp, rsp  */
    int local_bytes = locals * 8;
    if (local_bytes > 0) {
        /* sub rsp, imm32 */
        emit_u8(e, 0x48); emit_u8(e, 0x81); emit_u8(e, 0xec);
        emit_u32(e, (uint32_t)local_bytes);
    }
    /* Spill arg registers to locals 0..params-1. The ModR/M byte encodes
       `[rbp + disp32]` with the source register; REX.W=1, REX.R set for
       r8/r9. We're writing `mov r/m64, reg`. */
    static const uint8_t rex[6]   = { 0x48, 0x48, 0x48, 0x48, 0x4c, 0x4c };
    static const uint8_t modrm[6] = { 0xbd, 0xb5, 0x95, 0x8d, 0x85, 0x8d };
    for (int i = 0; i < params; i++) {
        int32_t disp = -((i + 1) * 8);
        emit_u8(e, rex[i]);
        emit_u8(e, 0x89);
        emit_u8(e, modrm[i]);
        emit_u32(e, (uint32_t)disp);
    }
}

/* ===========================================================================
 * Eligibility scan.
 * ========================================================================= */

/* Check that a single procedure's bytecode uses only ops the JIT supports
   AND has <=6 params AND no VAR params. Returns max(LOAD/STORE slot + 1,
   params) in *locals_out, the size of the frame the JIT needs to reserve. */
static bool locally_eligible(Procedure* p, int32_t* locals_out) {
    if (p->params > 6) return false;
    if (p->var_params > 0) return false;
    int32_t max_slot = p->params - 1;
    for (int32_t j = 0; j < p->codes_len; j++) {
        Op op = p->codes[j].op;
        switch (op) {
            case OP_PUSH: case OP_LOAD: case OP_STORE:
            case OP_MATH: case OP_COMPARE:
            case OP_JUMP: case OP_JUMP_IF_FALSE:
            case OP_RETURN: case OP_CALL:
                break;
            default:
                return false;
        }
        if (op == OP_LOAD || op == OP_STORE) {
            if (p->codes[j].arg > max_slot) max_slot = p->codes[j].arg;
        }
    }
    *locals_out = max_slot + 1;
    if (*locals_out < 0) *locals_out = 0;
    return true;
}

/* A procedure is JIT-eligible iff it is locally eligible AND every CALL
   target is also eligible. Propagated to fixpoint. */
static void run_eligibility(Program* program, int8_t* elig, int32_t* locals) {
    int n = program->procs_len;
    for (int i = 0; i < n; i++) {
        elig[i] = locally_eligible(&program->procs[i], &locals[i]) ? 1 : 0;
    }
    bool changed = true;
    while (changed) {
        changed = false;
        for (int i = 0; i < n; i++) {
            if (!elig[i]) continue;
            Procedure* p = &program->procs[i];
            for (int j = 0; j < p->codes_len; j++) {
                if (p->codes[j].op != OP_CALL) continue;
                int target = p->codes[j].arg;
                bool bad = (target < 0 || target >= n || !elig[target]);
                if (!bad) continue;
                Procedure* callee = &program->procs[target];
                /* Special-case: if the callee has params > 6 (or any other
                   issue), local_eligible already rejected it. We just
                   propagate the ineligibility. */
                (void)callee;
                elig[i] = 0;
                changed = true;
                break;
            }
        }
    }
}

/* ===========================================================================
 * Emit a single procedure. Returns true on success.
 * ========================================================================= */

static bool emit_proc(
    Procedure* p, int32_t locals, int proc_idx, Program* program,
    CrossCall* cc_list, int* cc_count, int cc_cap)
{
    size_t cap = 4096;
    uint8_t* code = mmap(NULL, cap,
                          PROT_READ | PROT_WRITE,
                          MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (code == MAP_FAILED) {
        perror("jit: mmap");
        return false;
    }
    Emitter e = {
        .code = code, .pos = 0, .cap = cap,
        .bc_to_code = calloc(p->codes_len > 0 ? p->codes_len : 1, sizeof(int32_t)),
        .patches = malloc(sizeof(JumpPatch) * 32),
        .patch_count = 0, .patch_cap = 32,
    };

    emit_prologue(&e, p->params, locals);

    for (int32_t j = 0; j < p->codes_len; j++) {
        e.bc_to_code[j] = (int32_t)e.pos;
        ByteCode* c = &p->codes[j];
        switch (c->op) {
            case OP_PUSH:
                emit_push_imm64(&e, (int64_t)c->arg);
                break;
            case OP_LOAD:
                emit_load_slot(&e, c->arg);
                break;
            case OP_STORE:
                emit_store_slot(&e, c->arg);
                break;
            case OP_MATH:
                emit_math(&e, c->kind);
                break;
            case OP_COMPARE:
                emit_compare(&e, c->kind);
                break;
            case OP_JUMP:
                emit_jmp_placeholder(&e, c->arg);
                break;
            case OP_JUMP_IF_FALSE:
                emit_jz_placeholder(&e, c->arg);
                break;
            case OP_CALL: {
                int callee_idx = c->arg;
                Procedure* callee = &program->procs[callee_idx];
                size_t imm_at;
                emit_call_placeholder(&e, callee->params, &imm_at);
                if (*cc_count >= cc_cap) {
                    fprintf(stderr, "jit: too many cross-calls\n");
                    exit(1);
                }
                cc_list[(*cc_count)++] = (CrossCall){ proc_idx, callee_idx, imm_at };
                break;
            }
            case OP_RETURN:
                emit_return(&e);
                break;
            default:
                /* eligibility scan should have prevented this */
                fprintf(stderr, "jit: unexpected op %d in eligible proc\n", c->op);
                free(e.bc_to_code); free(e.patches);
                munmap(code, cap);
                return false;
        }
    }

    /* Patch JUMP / JZ rel32s. */
    for (int k = 0; k < e.patch_count; k++) {
        int32_t target_off = e.bc_to_code[e.patches[k].bc_target];
        int32_t rel = target_off - ((int32_t)e.patches[k].patch_at + 4);
        emit_u32_at(code, e.patches[k].patch_at, (uint32_t)rel);
    }

    p->jit_fn = code;
    p->jit_code = code;
    p->jit_size = cap;

    free(e.bc_to_code);
    free(e.patches);
    return true;
}

/* ===========================================================================
 * Top-level entry point.
 * ========================================================================= */

int jit_compile_program(Program* program) {
    int n = program->procs_len;
    if (n <= 0) return 0;

    /* Allow the user to turn the JIT off entirely from the shell. */
    if (getenv("PUCK_JIT") && strcmp(getenv("PUCK_JIT"), "0") == 0) {
        return 0;
    }

    int8_t*  elig = calloc(n, sizeof(int8_t));
    int32_t* locals = calloc(n, sizeof(int32_t));
    run_eligibility(program, elig, locals);

    /* Cross-call patch records — one per OP_CALL we emit. Upper bound is
       total bytecode length across all procs. */
    int cc_cap = 0;
    for (int i = 0; i < n; i++) cc_cap += program->procs[i].codes_len;
    if (cc_cap < 16) cc_cap = 16;
    CrossCall* cc_list = malloc(sizeof(CrossCall) * cc_cap);
    int cc_count = 0;

    int compiled = 0;
    for (int i = 0; i < n; i++) {
        if (!elig[i]) continue;
        if (emit_proc(&program->procs[i], locals[i], i, program,
                       cc_list, &cc_count, cc_cap)) {
            compiled++;
        }
    }

    /* Now every eligible proc has a jit_fn set; walk the cross-calls and
       write the absolute callee address into each placeholder. */
    for (int k = 0; k < cc_count; k++) {
        Procedure* caller = &program->procs[cc_list[k].caller_idx];
        Procedure* callee = &program->procs[cc_list[k].callee_idx];
        emit_u64_at(caller->jit_code, cc_list[k].imm64_offset,
                     (uint64_t)(uintptr_t)callee->jit_fn);
    }

    /* Flip every code page to RX. */
    for (int i = 0; i < n; i++) {
        Procedure* p = &program->procs[i];
        if (p->jit_code) {
            if (mprotect(p->jit_code, p->jit_size, PROT_READ | PROT_EXEC) != 0) {
                perror("jit: mprotect");
                exit(1);
            }
        }
    }

    if (getenv("PUCK_JIT_TRACE")) {
        fprintf(stderr, "jit: compiled %d/%d procedures\n", compiled, n);
        for (int i = 0; i < n; i++) {
            if (program->procs[i].jit_fn) {
                fprintf(stderr, "jit:   proc %d  params=%d  locals=%d  -> %p\n",
                        i, program->procs[i].params, locals[i],
                        program->procs[i].jit_fn);
            }
        }
    }

    free(elig); free(locals); free(cc_list);
    return compiled;
}

#else  /* !__x86_64__ || !__linux__ */

int jit_compile_program(Program* program) {
    (void)program;
    return 0;
}

#endif
