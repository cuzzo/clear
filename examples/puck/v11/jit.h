/* v11 minimal JIT — public API.

   The whole JIT is one entry point. Call it after load_program has finished
   building the Program; it scans every procedure, decides which ones are
   pure-integer arithmetic (and only call other pure-integer procedures),
   emits x86_64 machine code for each into an mmap'd page, and stores a
   native function pointer in procedure->jit_fn. The interpreter sees
   jit_fn != NULL and routes CALL through the native code instead.

   Returns the number of procedures successfully compiled. Always safe to
   call: on non-x86_64-Linux builds it just returns 0 and the interpreter
   runs every procedure correctly. */

#ifndef PUCK_V11_JIT_H
#define PUCK_V11_JIT_H

#include "vm_types.h"

int jit_compile_program(Program* program);

#endif
