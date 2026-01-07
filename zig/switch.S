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
    movq 0x38(%rsi), %r10   # Load the stack_limit from 'to' context into R10 # TODO: USE STACK_LIMIT_OFFSET
    movq 0x00(%rsi), %rsp

    # 3. Swap
    ret

.global __morestack
__morestack:
    # If we hit this, LLVM has detected we are about to overflow.
    # We are still on the Fiber stack, but it's too late to save it.

    # We jump to G0 to print the error safely so we don't
    # use any more Fiber stack space.
    jmp panic_stack_overflow_asm

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
    ldr x10, [x1, #0x70]       # Load the stack_limit into x10  # TODO: USE STACK_LIMIT_OFFSET
    ldr x9, [x1, #0x00]
    mov sp, x9
    ret

.global __morestack
.align 2
__morestack:
    # On ARM64, we use 'b' for branch
    b panic_stack_overflow_asm

#endif
