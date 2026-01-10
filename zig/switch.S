# switch.s

.macro SNAPSHOT label_rip, destination
    pushq %rax
    pushq %rcx

    # CHANGE: Load the specific destination struct address
    leaq \destination(%rip), %rcx

    movq %rbx, 8(%rcx)

    # Save Orig RCX (from stack)
    movq (%rsp), %rax    # RAX = OrigRCX
    movq %rax, 16(%rcx)  # struct.rcx

    movq %rdx, 24(%rcx)
    movq %rdi, 32(%rcx)
    movq %rsi, 40(%rcx)
    movq %rbp, 48(%rcx)

    # RSP Calculation: We pushed 2 regs (16 bytes).
    leaq 16(%rsp), %rax
    movq %rax, 56(%rcx)  # struct.rsp

    movq %r8,  64(%rcx)
    movq %r9,  72(%rcx)
    movq %r10, 80(%rcx)
    movq %r11, 88(%rcx)
    movq %r12, 96(%rcx)
    movq %r13, 104(%rcx)
    movq %r14, 112(%rcx)
    movq %r15, 120(%rcx)

    leaq \label_rip(%rip), %rax
    movq %rax, 128(%rcx) # struct.rip

    # Save Orig RAX (from stack offset 8)
    movq 8(%rsp), %rax   # RAX = OrigRAX
    movq %rax, 0(%rcx)   # struct.rax

    popq %rcx
    popq %rax
.endm


.data
.global breadcrumb_counter
.global breadcrumbs
breadcrumb_counter: .quad 0
breadcrumbs: .space 512  # 64 breadcrumbs

.macro CRUMB id
    pushq %rax
    pushq %rdx
    movq breadcrumb_counter(%rip), %rax
    leaq breadcrumbs(%rip), %rdx
    movq $\id, (%rdx, %rax, 8)
    incq %rax
    movq %rax, breadcrumb_counter(%rip)
    popq %rdx
    popq %rax
.endm


# Strictly check for 16-byte alignment
# Do NOT push anything before this check.
.macro CHECK_ALIGN error_code
    testq $15, %rsp
    jz .Lok_\@
    movq $\error_code, %rdi
    call abi_panic
.Lok_\@:
.endm

.macro SAVE_ENTRY_STATE
    movq %rbx, entry_rbx(%rip)
    movq %rbp, entry_rbp(%rip)
    movq %r12, entry_r12(%rip)
    movq %r13, entry_r13(%rip)
    movq %r14, entry_r14(%rip)
    movq %r15, entry_r15(%rip)
.endm

.macro CHECK_CALLEE_SAVED error_code
    cmpq entry_rbx(%rip), %rbx
    jne .Lbad_\@
    cmpq entry_rbp(%rip), %rbp
    jne .Lbad_\@
    cmpq entry_r12(%rip), %r12
    jne .Lbad_\@
    cmpq entry_r13(%rip), %r13
    jne .Lbad_\@
    cmpq entry_r14(%rip), %r14
    jne .Lbad_\@
    cmpq entry_r15(%rip), %r15
    jne .Lbad_\@
    jmp .Lgood_\@
.Lbad_\@:
    movq $\error_code, %rdi
    call abi_panic
.Lgood_\@:
.endm

# DO NOT use between a comparison and a jump.
# cmpq $10, %rax
# CHECK_RSP_VALID 9999   # <--- THIS IS BAD. It overwrites the result of cmpq!
# je label_equal         # <--- This jump now depends on the macro's math, not your cmpq!
.macro CHECK_RSP_VALID error_code
    # Protect registers we use
    pushq %rax
    pushq %rcx    # Save RCX so we don't corrupt it

    movq %rsp, %rax
    addq $16, %rax            # Account for our 2 pushes (RAX + RCX)

    # Check Lower Bound (NULL/Low mem protection)
    cmpq $0x1000, %rax
    jb .Lbad_\@

    # Check Upper Bound (User space limit)
    movq $0x7fffffffffff, %rcx
    cmpq %rcx, %rax
    ja .Lbad_\@

    # Restore registers
    popq %rcx
    popq %rax
    jmp .Lgood_\@

.Lbad_\@:
    # Ensure stack is clean before we panic, though we are dying anyway
    popq %rcx
    popq %rax
    movq $\error_code, %rdi
    call abi_panic
.Lgood_\@:
.endm

.macro CHECK_NOT_NULL reg, error_code
    testq \reg, \reg
    jz .Lnull_\@      # Jump if Zero (NULL)
    jmp .Lok_\@

.Lnull_\@:
    movq $\error_code, %rdi
    call abi_panic
.Lok_\@:
.endm



.data
.global abi_error_code
abi_error_code: .quad 0


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
    CHECK_RSP_VALID 9100
    CRUMB 1000

    /* 1. Save callee-saved registers on OLD stack */
    /* Stack alignment note: We entered via a CALL, so RSP ends in 8 */
    pushq %rbp  # RSP...0
    pushq %r12  # RSP...8
    pushq %r13  # RSP...0
    pushq %r14  # RSP...8
    pushq %r15  # RSP...0
    pushq %rbx  # RSP...8

    CRUMB 1001
    /* 2. Snapshot pointer (The Anchor) */
    /* R12 now holds the address of the "Old Stack Top" */
    movq %rsp, %r12

    CRUMB 1002
    /* 3. Switch to parent stack (TLS Logic) */
    /* UNTESTED: Ensure your test harness mocks this or runs on Linux with libc */
    movq __fiber_parent_ctx@gottpoff(%rip), %rax
    movq %fs:(%rax), %rax
    movq (%rax), %rsp

    /* Force alignment for the upcoming C ABI call */
    andq $-16, %rsp

    CHECK_RSP_VALID 9101
    CRUMB 1003
    CHECK_ALIGN 9001

    /* 4. Save volatile args (C calling convention preservation) */
    pushq %rdi
    pushq %rsi
    pushq %rdx
    pushq %rcx
    pushq %r8
    pushq %r9

    /* 5. Pass snapshot pointer to allocator */
    /* FIX: Used R12 (the actual snapshot), not R11 (garbage) */
    movq %r12, %rdi

    CRUMB 1004
    call __zig_alloc_segment
    CRUMB 1005

    /* RAX now holds the NEW stack pointer */

    /* 6. Restore volatile args */
    popq %r9
    popq %r8
    popq %rcx
    popq %rdx
    popq %rsi
    popq %rdi

    /* 7. Pivot to new stack */
    /* The allocator returns the top of stack. We need to reserve space
       for our variables, but we are about to push, so just move RSP. */
    movq %rax, %rsp
    CHECK_RSP_VALID 9102

    /* 8. Setup Linkage */
    /* FIX: Push R12 (Old Stack Ptr) as the link, not R11 */
    pushq %r12                  /* link back to old frame */

    leaq __lessstack(%rip), %rax
    pushq %rax                  /* return target on new stack */

    SNAPSHOT morestack_post_pivot

    /* 9. Restore callee-saved registers from Snapshot */
    /* NOTE: We are reading from R12 (Old Stack), but NOT popping.
       The Old Stack stays frozen until __lessstack pops it later. */

    movq 0(%r12), %rbx
    movq 8(%r12), %r15   /* FIX: Use R12, not R11 */
    movq 16(%r12), %r14  /* FIX: Use R12 */
    movq 24(%r12), %r13  /* FIX: Use R12 */
    movq 32(%r12), %r12  /* Note: This restores the R12 VALUE, not the snapshot ptr */
    movq 40(%r12), %rbp

    /* 10. Resume execution at continuation */
    /* The return address was pushed onto the old stack BEFORE we saved regs.
       So it is at 48(%r12_snapshot). */
    /* FIX: Use offset 48 off the snapshot */
    movq 48(%r12), %rax
    jmp *%rax

morestack_post_pivot:
    nop

.global __lessstack
__lessstack:
    CRUMB 2000

    /* 1. Pivot back to the Old Stack */
    /* The link (Old SP) was pushed right before the return address.
       RSP points to it now. */
    popq %rsp

    CHECK_RSP_VALID 9103
    CRUMB 2001

    /* 2. Restore Callee-Saved Registers */
    /* We are now back on the Old Stack, exactly where R12 pointed earlier. */
    popq %rbx
    popq %r15
    popq %r14
    popq %r13
    popq %r12

    /* FIX: Do NOT use 'movq %rbp, %rsp'. Just pop. */
    popq %rbp

    CRUMB 2002
    /* 3. Return to original caller */
    ret


.text
.global test_morestack_simple
.type test_morestack_simple, @function
test_morestack_simple:
    /* 1. Save the REAL Zig stack pointer so we can escape later */
    movq %rsp, test_saved_rsp(%rip)

    /* 2. Load the constants you want to see in the snapshot */
    movq $0xBBBBBBBBBBBBBBBB, %rbx
    movq $0xAAAAAAAAAAAAAAAA, %rbp

    /* 3. Push the STOP POINT as the return address.
       This is what morestack will load into RAX and JMP to. */
    leaq test_morestack_stop(%rip), %rax
    pushq %rax

    /* 4. Run morestack logic */
    jmp __morestack

.global test_morestack_stop
.type test_morestack_stop, @function
test_morestack_stop:
    /* We are now at the very end of morestack.
       The SNAPSHOT has already fired.
       RSP is currently on the NEW stack.
       We ignore everything and jump back to the Zig stack. */
    movq test_saved_rsp(%rip), %rsp
    ret


.data
.balign 8
.global test_saved_rsp
test_saved_rsp: .quad 0


.text
.global test_lessstack_harness
test_lessstack_harness:
    # RDI = Address of the "New Stack" (which points to the Old Stack)

    # 1. Save the REAL test runner stack
    movq %rsp, test_saved_rsp(%rip)

    # 2. Switch to the fake "New Stack" provided by Zig
    movq %rdi, %rsp

    # 3. Jump into the logic under test
    jmp __lessstack


.global test_restore_point
test_restore_point:
    # If we get here, __lessstack successfully pivoted and "returned".
    # We must now CAPTURE the registers to verify they were restored.

    pushq %rax
    leaq debug_capture(%rip), %rax

    movq %rbx, 8(%rax)   # struct.rbx
    movq %r12, 96(%rax)  # struct.r12
    movq %r13, 104(%rax) # struct.r13
    movq %r14, 112(%rax) # struct.r14
    movq %r15, 120(%rax) # struct.r15
    movq %rbp, 48(%rax)  # struct.rbp

    popq %rax

    # 4. Restore the REAL test runner stack and exit
    movq test_saved_rsp(%rip), %rsp
    ret







.global test_simple_stack_switch
test_simple_stack_switch:
    CRUMB 2000

    # Save callee-saved
    pushq %rbx
    pushq %r12

    CRUMB 2001
    movq %rsp, %r12     # R12 = snapshot of old stack

    CRUMB 2002
    # "Allocate new stack" (fake - just move down)
    subq $1024, %rsp
    andq $-16, %rsp

    CRUMB 2003
    # Push link to old stack
    pushq %r12

    CRUMB 2004
    # Push fake return
    leaq test_lessstack_simple(%rip), %rax
    pushq %rax

    CRUMB 2005
    # Get return address from old stack
    movq 16(%r12), %rax    # Skip over our 2 pushes

    CRUMB 2006
    # Jump to it (simulating continuation)
    jmp *%rax

.global test_lessstack_simple
test_lessstack_simple:
    CRUMB 3000

    # Pop old stack pointer
    popq %rsp

    CRUMB 3001
    # Restore callee-saved
    popq %r12
    popq %rbx

    CRUMB 3002
    ret



.text
.global test_breadcrumbs
test_breadcrumbs:
    CRUMB 100
    CRUMB 200
    CRUMB 300
    ret


.text
.global test_fake_return
test_fake_return:
    CRUMB 1000

    # Pop the real return address
    popq %rax

    CRUMB 1001

    # Push a fake return address
    leaq fake_target(%rip), %rbx
    pushq %rbx

    CRUMB 1002

    # Jump somewhere that will ret
    jmp does_simple_ret

fake_target:
    CRUMB 2000
    # We landed here from does_simple_ret
    # Now return to real caller (it's in RAX)
    pushq %rax
    ret

does_simple_ret:
    CRUMB 3000
    # This ret will jump to fake_target
    ret






.text
.global test_snapshot_survives
test_snapshot_survives:
    CRUMB 1000

    # Save a register
    pushq %rbx

    CRUMB 1001

    # Snapshot points to RBX
    movq %rsp, %r12

    CRUMB 1002

    # Move stack pointer past the saved value
    addq $8, %rsp

    CRUMB 1003

    # Pop real return (now at top of stack)
    popq %rax

    CRUMB 1004

    # Push fake return
    leaq fake_target2(%rip), %rbx
    pushq %rbx

    CRUMB 1005

    jmp does_ret2

fake_target2:
    CRUMB 2000

    # R12 still points to saved RBX
    movq 0(%r12), %rbx

    CRUMB 2001

    # Restore stack (move back down to where RBX was)
    movq %r12, %rsp

    CRUMB 2002

    # Pop RBX off
    popq %rbx

    CRUMB 2003

    # Return
    pushq %rax
    ret

does_ret2:
    CRUMB 3000
    ret





.data
.global entry_rbx
.global entry_rsp
.global entry_rbp
.global entry_r12
.global entry_r13
.global entry_r14
.global entry_r15
.global fake_stack

fake_stack: .space 2048  # 2KB fake stack
entry_rsp: .quad 0
entry_rbx: .quad 0
entry_rbp: .quad 0
entry_r12: .quad 0
entry_r13: .quad 0
entry_r14: .quad 0
entry_r15: .quad 0

.text
.global test_stack_switch
test_stack_switch:
    SAVE_ENTRY_STATE
    CHECK_RSP_VALID 9100
    movq %rsp, entry_rsp(%rip)

    CRUMB 1000

    # Save callee-saved
    pushq %rbx
    pushq %r12          # Save R12 before overwriting it

    CRUMB 1001

    # Snapshot NOW (RSP points to R12, then RBX, then Return Address)
    movq %rsp, %r12

    CRUMB 1002
    CHECK_NOT_NULL %r12, 9101

    # Get return address (don't pop, just read)
    # 0(%r12)  = Saved R12
    # 8(%r12)  = Saved RBX
    # 16(%r12) = Return Address
    movq 16(%r12), %rax

    CRUMB 1003

    # Switch to fake stack
    leaq fake_stack(%rip), %rsp
    addq $2048, %rsp
    andq $-16, %rsp

    CHECK_RSP_VALID 9102
    CHECK_ALIGN 9001      # Check new stack is aligned
    CRUMB 1004

    # Push link back to old stack
    pushq %r12

    CRUMB 1005
    SNAPSHOT test_before_switch, capture_pivot

    # Push fake return
    leaq restore_stack(%rip), %r11
    pushq %r11

    CHECK_ALIGN 9002      # Check still aligned after pushes
    CRUMB 1006

    jmp does_ret3

restore_stack:
    CRUMB 2000

    # Pop old stack pointer
    popq %rsp
    CHECK_RSP_VALID 9103

    CRUMB 2001

    # Restore Callee-saved (LIFO order)
    popq %r12           # Restore R12
    popq %rbx           # Restore RBX

    CRUMB 2002
    CHECK_CALLEE_SAVED 9003   # Check callee-saved before return
    SNAPSHOT test_restore_done, capture_restore

    # RSP is ALREADY pointing to the return address.
    # We do NOT push %rax. Just return.
    ret

does_ret3:
    CRUMB 3000
    ret

.global test_before_switch
test_before_switch:
    nop

.global test_restore_done
test_restore_done:
    nop


