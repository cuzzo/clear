/* TEST HELPER: test_victim_fn
   Defined here to ensure global visibility to the linker.
   It accesses the exported Zig variables directly.
*/
.global test_victim_fn
.type test_victim_fn, @function
test_victim_fn:
    pushq %rbp
    movq %rsp, %rbp
    movq %rsp, sp_before_morestack(%rip)
    call __morestack
    movq %rsp, sp_inside_morestack(%rip)
    ret

.global minimal_pivot_asm
.type minimal_pivot_asm, @function
minimal_pivot_asm:
    pushq %rbp
    movq %rsp, %rbp
    pushq %r12             /* Save old RSP in R12 */
    movq %rsp, %r12

    /* Switch to new stack */
    movq %rsi, %rsp

    /* Setup Hijack */
    leaq .land_here(%rip), %rax
    pushq %rax

    /* Jump */
    jmp *%rdi

.land_here:
    /* Pivot back */
    movq %r12, %rsp
    popq %r12
    popq %rbp
    ret

.global level2_snapshot_asm
.type level2_snapshot_asm, @function
level2_snapshot_asm:
    pushq %rbp             /* ABI Frame */
    movq %rsp, %rbp

    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15

    movq %rsp, %r11        /* Snapshot anchor */

    /* Switch */
    movq %rsi, %rsp

    /* Link */
    pushq %r11
    leaq .unstitch(%rip), %rax
    pushq %rax

    jmp *%rdi

.unstitch:
    popq %rsp              /* Pivot back to anchor */

    popq %r15
    popq %r14
    popq %r13
    popq %r12

    popq %rbp              /* Restore ABI Frame */
    ret

.global level3_parent_switch_asm
.type level3_parent_switch_asm, @function
level3_parent_switch_asm:
    pushq %rbp
    movq %rsp, %rbp

    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    movq %rsp, %r12

    /* SWITCH TO PARENT STACK */
    movq %rsp, %r13
    movq (%rdx), %rsp

    andq $-16, %rsp
    subq $8, %rsp
    cld
    call level3_zig_helper

    /* RESTORE */
    movq %r13, %rsp

    /* PIVOT TO NEW */
    movq %rsi, %rsp
    pushq %r12
    leaq 1f(%rip), %rax
    pushq %rax

    jmp *%rdi

1:
    popq %rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbp
    ret


.global level4_tls_test_asm
.type level4_tls_test_asm, @function
level4_tls_test_asm:
    /* 1. Resolve the TLS offset from the Global Offset Table */
    movq __fiber_parent_ctx@gottpoff(%rip), %rax

    /* 2. Add the FS segment base to the offset to get the absolute address */
    movq %fs:(%rax), %rax

    /* 3. Return the address found in rax */
    ret



/* TEST HARNESS
   This invokes __morestack manually.
   FIX: We must create a "Fake Stack Frame" so that __lessstack's
   smart unwind (mov %rbp, %rsp) returns to .Lcleanup instead of
   blowing past it to the caller.
*/
.global test_harness
test_harness:
    /* Frame 1: Real Harness Frame */
    pushq %rbp
    movq %rsp, %rbp
    pushq %r12              /* Preserve R12 */

    /* FRAME 2: FAKE FRAME for __morestack
       We manually construct a stack frame here.
       When __lessstack unwinds, it will pop this frame and 'ret' to .Lcleanup.
    */

    /* 1. Push the return address we want (__lessstack will return here) */
    leaq .Lcleanup(%rip), %rax
    pushq %rax

    /* 2. Push the Caller's RBP (Our current RBP) */
    pushq %rbp

    /* 3. Update RBP to point to this new frame.
       This is what __morestack will save/restore.
       When __lessstack does 'mov %rbp, %rsp', RSP will point here. */
    movq %rsp, %rbp

    /* 4. Capture the stack pointer (relative to this new frame) */
    movq %rsp, sp_before_morestack(%rip)

    /* 5. Push the "Continuation Address" (Body entry point) */
    /* __morestack treats 40(%r11) as the target jump */
    leaq .Lbody(%rip), %rax
    pushq %rax

    /* 6. Jump to __morestack */
    jmp __morestack

.Lcleanup:
    /* __lessstack returns here! */
    /* The stack is now: [SavedR12] [SavedRBP] (From Frame 1) */
    /* Note: 'popq %rbp' in the fake frame restored the Frame 1 RBP for us. */

    movq %rsp, sp_after_return(%rip)

    popq %r12
    popq %rbp
    ret

.Lbody:
    /* Runs on new stack */
    movq %rsp, sp_inside_morestack(%rip)
    ret




/* RUN MICROSCOPE
   Same fix as test_harness: Nested fake frame for the unwinder.
*/
.global run_microscope
.type run_microscope, @function
run_microscope:
    /* Frame 1: Real Frame */
    pushq %rbp
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    pushq %rbx

    /* Save Real RSP before switching */
    movq %rsp, real_rsp_save(%rip)

    /* Switch to Fake Stack Buffer */
    movq %rdi, %rsp

    /* Establish Frame 1 RBP on the fake stack (for stability) */
    movq %rsp, %rbp

    /* FRAME 2: FAKE FRAME */

    /* 1. Push Return Address (restore_finish) */
    leaq restore_finish(%rip), %rax
    pushq %rax

    /* 2. Push Saved RBP */
    pushq %rbp

    /* 3. Set RBP to current RSP (The "Fake Frame" base) */
    movq %rsp, %rbp

    /* 4. Push Continuation (Body) */
    leaq inspector_gadget(%rip), %rax
    pushq %rax

    /* 5. Jump */
    jmp __morestack

inspector_gadget:
    /* Runs on NEW STACK */
    movq %rsp, microscope_new_sp(%rip)

    /* Peek at stack bottom */
    popq %r15                   /* __lessstack */
    popq %r14                   /* Old RSP */
    movq %r14, microscope_old_sp_ref(%rip)

    /* Restore and return */
    pushq %r14
    pushq %r15
    ret

.global restore_finish
restore_finish:
    /* We returned to the fake stack. */

    /* Restore Real Stack Pointer */
    movq real_rsp_save(%rip), %rsp

    /* Restore Registers */
    popq %rbx
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbp
    ret

/* Global Variables */
.section .data
.global real_rsp_save
real_rsp_save: .quad 0

.global microscope_new_sp
microscope_new_sp: .quad 0

.global microscope_old_sp_ref
microscope_old_sp_ref: .quad 0


/* TEST ABI PRESERVATION
   Simulates a function that takes arguments (RDI, RSI)
   hitting the stack limit.
*/
.global test_abi_clobber_asm
.type test_abi_clobber_asm, @function
test_abi_clobber_asm:
    /* 1. Prologue */
    pushq %rbp
    movq %rsp, %rbp

    /* 2. Save Registers (On OLD STACK) */
    pushq %rbx
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15

    /* 3. Load Test Values */
    movq $0xCAFEBABEDEADBEEF, %rdi
    movq $0x123456789ABCDEF0, %rsi

    /* 4. Trigger Stack Switch */
    leaq .Lresume_abi(%rip), %rax
    pushq %rax
    call __morestack

.Lresume_abi:
    /* 5. Verify Registers */
    movq $0xCAFEBABEDEADBEEF, %rax
    cmpq %rax, %rdi
    jne .fail_abi
    movq $0x123456789ABCDEF0, %rax
    cmpq %rax, %rsi
    jne .fail_abi

    /* 6. CONTEXT CHECK */
    leaq __lessstack(%rip), %rax
    cmpq (%rsp), %rax
    jne .on_old_stack

.on_new_stack:
    /* First pass: return into __lessstack */
    ret

.on_old_stack:
    /* Second pass: restore our own frame */
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret

.fail_abi:
    ud2

