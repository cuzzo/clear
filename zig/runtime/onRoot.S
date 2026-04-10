#if defined(__x86_64__)

.section .text
.global call_on_stack_asm
.type call_on_stack_asm, @function

# RDI = new_stack_ptr, RSI = func_ptr, RDX = arg_ptr
call_on_stack_asm:
    # --- PROLOGUE: Save Fiber State ---
    pushq %rbp
    movq %rsp, %rbp

    # Save all callee-saved registers (Optional but safer for complex C calls)
    pushq %rbx
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15

    # --- THE SWITCH ---
    movq %rsp, %r8       # Store fiber SP (after pushes) to r8
    movq %rdi, %rsp      # JUMP TO G0 STACK

    # --- ALIGNMENT & CALL ---
    andq $-16, %rsp      # Force 16-byte alignment
    pushq %r8            # Save fiber SP on G0 stack for recovery

    # We must save the floating point control word if we want to be 100% production safe
    subq $8, %rsp
    stmxcsr (%rsp)       # Save SSE control state

    movq %rdx, %rdi      # Move arg_ptr to RDI (1st arg)
    call *%rsi           # CALL THE C/ZIG FUNCTION

    # --- EPILOGUE: Return to Fiber ---
    ldmxcsr (%rsp)       # Restore SSE control state
    addq $8, %rsp

    popq %rsp            # RESTORE FIBER SP (RSP is back on fiber stack)

    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret

#endif

#if defined(__aarch64__)

.section .text
.global call_on_stack_asm
.align 2

# x0 = new_stack_ptr, x1 = func_ptr, x2 = arg_ptr
call_on_stack_asm:
    # 1. Push FP, LR and the current SP to the Fiber stack
    mov x9, sp
    stp x29, x30, [sp, #-48]!  # Allocate 48 bytes (16-byte aligned)
    mov x29, sp
    str x9, [sp, #16]          # Save Fiber SP

    # 2. Save Floating Point status
    mrs x10, fpcr
    str x10, [sp, #24]

    # 3. Switch to G0
    and x0, x0, #~0xf          # Ensure 16-byte align
    mov sp, x0

    # 4. Execute
    mov x0, x2                 # arg_ptr -> x0
    blr x1

    # 5. Restore
    mov sp, x29                # Switch back to Fiber stack frame
    ldr x10, [sp, #24]         # Restore FP Control
    msr fpcr, x10
    ldr x9, [sp, #16]          # Load Fiber SP
    ldp x29, x30, [sp], #48    # Pop and Clean up
    mov sp, x9
    ret

#endif

