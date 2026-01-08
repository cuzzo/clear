# switch.s

# Check for x86_64 (Linux/Intel)
#if defined(__x86_64__)

.section .text
.global switch_context_asm
.type switch_context_asm, @function

switch_context_asm:
    # 1. Save Current Registers to 'from' (RDI)
    movq %rsp, 0x00(%rdi)
    movq %rbx, 0x08(%rdi)
    movq %rbp, 0x10(%rdi)
    movq %r12, 0x18(%rdi)
    movq %r13, 0x20(%rdi)
    movq %r14, 0x28(%rdi)
    movq %r15, 0x30(%rdi)

    # 2. Load New Registers from 'to' (RSI)
    movq 0x30(%rsi), %r15
    movq 0x28(%rsi), %r14
    movq 0x20(%rsi), %r13
    movq 0x18(%rsi), %r12
    movq 0x10(%rsi), %rbp
    movq 0x08(%rsi), %rbx
    movq 0x00(%rsi), %rsp

    # 3. Swap
    ret

#endif

# Check for ARM64 (Apple Silicon/Linux ARM)
#if defined(__aarch64__)

.section .text
.global switch_context_asm
.align 2

switch_context_asm:
    # x0 = from, x1 = to
    mov x9, sp
    str x9, [x0, #0x00]
    stp x19, x20, [x0, #0x10]
    stp x21, x22, [x0, #0x20]
    stp x23, x24, [x0, #0x30]
    stp x25, x26, [x0, #0x40]
    stp x27, x28, [x0, #0x50]

    ldp x27, x28, [x1, #0x50]
    ldp x25, x26, [x1, #0x40]
    ldp x23, x24, [x1, #0x30]
    ldp x21, x22, [x1, #0x20]
    ldp x19, x20, [x1, #0x10]
    ldr x9, [x1, #0x00]
    mov sp, x9
    ret

#endif


.global __morestack
.type __morestack, @function
__morestack:
    /* Save callee-saved registers on OLD stack */
    pushq %rbp
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    pushq %rbx

    /* Snapshot pointer */
    movq %rsp, %r11

    /* Switch to parent stack */
    movq __fiber_parent_ctx@gottpoff(%rip), %rax
    movq %fs:(%rax), %rax
    movq (%rax), %rsp
    andq $-16, %rsp

    /* Save volatile args */
    pushq %rdi
    pushq %rsi
    pushq %rdx
    pushq %rcx
    pushq %r8
    pushq %r9

    /* Pass snapshot pointer to allocator */
    pushq %r11
    subq $8, %rsp
    movq %r11, %rdi
    call __zig_alloc_segment
    addq $8, %rsp
    popq %r11

    /* Restore volatile args */
    popq %r9
    popq %r8
    popq %rcx
    popq %rdx
    popq %rsi
    popq %rdi

    /* Pivot to new stack */
    subq $8, %rax
    movq %rax, %rsp
    pushq %r11                 /* link back to old frame */
    leaq __lessstack(%rip), %rax
    pushq %rax                 /* return target on new stack */

    /* Restore callee-saved registers */
    movq 0(%r11), %rbx
    movq 8(%r11), %r15
    movq 16(%r11), %r14
    movq 24(%r11), %r13
    movq 32(%r11), %r12
    movq 40(%r11), %rbp

    /* Resume execution at continuation */
    movq 48(%r11), %rax       /* original continuation */
    jmp *%rax


.global __lessstack
__lessstack:
    /* 1. Pivot back to the Old Stack */
    popq %rsp

    /* 2. Restore Callee-Saved Registers */
    /* CRITICAL: You must pop RBX first because it was pushed last! */
    popq %rbx

    popq %r15
    popq %r14
    popq %r13
    popq %r12

    /* 3. Smart Unwind */
    movq %rbp, %rsp
    popq %rbp
    ret

