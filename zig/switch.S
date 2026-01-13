# switch.s

.data
.global breadcrumb_counter
.global breadcrumbs
.global abi_error_code
abi_error_code: .quad 0
breadcrumb_counter: .quad 0
breadcrumbs: .space 512  # 64 breadcrumbs

.data
.balign 8
.global test_saved_rsp
test_saved_rsp: .quad 0

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
.cfi_sections .eh_frame

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

# -----------------------------------------------------------------------
# The Macro
# -----------------------------------------------------------------------
.macro CRUMB id
    # 1. Update Global Counter (Quickly)
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
    .cfi_startproc
    SAVE_ENTRY_STATE
    CHECK_RSP_VALID 9100
    movq %rsp, entry_rsp(%rip)

    CRUMB 1000

    # Save callee-saved
    # Save Caller's RBX before overwriting it
    pushq %rbx
    .cfi_def_cfa_offset 16
    .cfi_offset %rbx, -16

    # Save Caller's R12 before overwriting it
    pushq %r12
    .cfi_def_cfa_offset 24
    .cfi_offset %r12, -24

    # Save Caller's R13 before overwriting it
    pushq %r13
    .cfi_def_cfa_offset 32
    .cfi_offset %r13, -32

    # Save Caller's R14
    pushq %r14
    .cfi_def_cfa_offset 40
    .cfi_offset %r14, -40

    # Save Caller's R15
    pushq %r15
    .cfi_def_cfa_offset 48
    .cfi_offset %r15, -48

    # Save Caller's RBP
    pushq %rbp
    .cfi_def_cfa_offset 56
    .cfi_offset %rbp, -56

    CRUMB 1001

    # Snapshot NOW
    # RSP points to R12, then RBX, then Return Address
    movq %rsp, %r12
    #.cfi_def_cfa_register %r12

    # Save CURRENT stack limit to later restore
    movq test_stack_limit@gottpoff(%rip), %rax  # Load Offset from GOT
    movq %fs:(%rax), %r13                       # Read from FS + Offset

    CRUMB 1002
    CHECK_NOT_NULL %rax, 9101

    # Get return address (don't pop, just read)
    # 0(Dummy), 8(R15), 16(R14), 24(R13), 32(R12), 40(RBX), 48(RET)
    # This is perfect inverse of `Save Callee-saved` above
    movq 48(%r12), %rax

    CRUMB 1003

    # ---------------------------------------------------------------------
    # Switch to EMERGENCY STACK: We are out of space
    # ---------------------------------------------------------------------
    # Load the "Parent Context" pointer from TLS
    movq test_parent_ctx@gottpoff(%rip), %rax
    movq %fs:(%rax), %rax                          # RAX now holds *MockContext

    CHECK_NOT_NULL %r12, 9102

    # 1. We are still on the old stack.
    # Snapshot RSP into R11 (Volatile/Caller-saved)
    # We use R11 because you HAVE NOT issued a .cfi_offset for it.
    #movq %rsp, %r11

    # 3. Switch RSP to the Parent's SP
    .cfi_endproc                                  # BUYER BEWARE: UNWINDING IS TEMPORARILY IMPOSSIBLE
    movq (%rax), %rsp                             # We are now on the emergency stack. The old stack (R12) is frozen.
    CHECK_RSP_VALID 9200                          # ENSURE VALIDITY!
    andq $-16, %rsp                               # FORCE ALIGNMENT!

    # ---------------------------------------------------------------------
    # Prepare for Zig call - Save volatile regs, call, restore
    # ---------------------------------------------------------------------

    # 1. Save Volatiles (Allocator will clobber these)
    pushq %rdi
    pushq %rsi
    pushq %rdx
    pushq %rcx
    pushq %r8
    pushq %r9

    # 2. Setup Argument: RDI = Old Stack Snapshot
    movq %r12, %rdi

    # 3. Call Allocator
    CHECK_ALIGN 9050
    call __mock_zig_alloc_segment                  # CALL ON EMERGECY STACK!

    # 3.1: Die if already overflown
    testq %rax, %rax
    jz handle_overflow_error

    # 4. Restore Volatiles (Pop in reverse order)
    popq %r9
    popq %r8
    popq %rcx
    popq %rdx
    popq %rsi
    popq %rdi

    # 5. Switch Stack
    # RAX holds the new stack pointer returned by mock_alloc_stack
    # RAX holds returned values...
    movq %rax, %rsp                     # We are now running on the stitched stack (The new segment)

    CRUMB 1004

    # --- START NEW FRAME UNWIND LOGIC ---
    movq 48(%r12), %r11
    pushq %r11                          # synthetic return address
    pushq %rbp                          # save caller's RBP
    movq %rsp, %rbp
    # --- END NEW FRAME UNWIND LOGIC ---

    CHECK_ALIGN 9051

    # 6. Populate new stack with state:
    pushq %r13                          # Old Stack Limit
    pushq %r12                          # Old Stack Pointer

    # ---------------------------------------------------------------------
    # END Zig Call
    # ---------------------------------------------------------------------

    movq %rsp, %r11                     # Calc New Limit
    subq $2048, %r11                    # Bottom = Top - Size

    # Update TLS stack limit to the new limit (stored in %r11)
    movq test_stack_limit@gottpoff(%rip), %rax
    movq %r11, %fs:(%rax)

    CHECK_RSP_VALID 9103
    CHECK_ALIGN 9001                    # Check new stack is aligned
    CRUMB 1005

    SNAPSHOT test_before_switch, capture_pivot

    # Push fake return
    leaq __lessstack(%rip), %r11
    pushq %r11

    CRUMB 1006

    # Retrieve old return address from frozen R12, store it in R11, jump to it.
    movq 48(%r12), %r11
    jmp *%r11

.global __lessstack
.type __lessstack, @function
__lessstack:
    .cfi_startproc
    CRUMB 2000

    # RESTORE LOGIC (LIFO) -> Current Stack Layout:
    # RSP+8  = Saved R12 (Old SP)
    # RSP+16 = Saved R13 (Old Limit)
    # RSP+24 = Saved RBP (For DWARF / Unwind)

    # 1. Restore TLS Stack Limit (written in memory at start of new stack)
    movq 8(%rsp), %r11
    movq test_stack_limit@gottpoff(%rip), %rcx
    movq %r11, %fs:(%rcx)

    # 2. Restore rpb for unwinding
    movq (%rbp), %rbp

    # 3. Pop old stack pointer
    movq 0(%rsp), %rsp                  # We are now back on the original fiber stack.
    #.cfi_def_cfa_register %rsp
    CHECK_RSP_VALID 9105

    cmpq %rsp, %r12
    jne panic_alignment_mismatch

    movq entry_rsp(%rip), %r11
    subq $48, %r11                      # Adjust for the 6 pushes
    cmpq %rsp, %r11
    jne panic_stack_depth_mismatch

    CRUMB 2001

    # Restore Callee-saved (LIFO order)
    # This must be exact inverse of `Save Callee-saved` above
    # Restore RBP
    popq %rbp
    #.cfi_def_cfa_offset 48
    #.cfi_restore %rbp

    # Restore R15
    popq %r15
    #.cfi_def_cfa_offset 40
    #.cfi_restore %r15

    popq %r14
    #.cfi_def_cfa_offset 32
    #.cfi_restore %r14

    # Restore R13 (which was clobbered)
    popq %r13
    #.cfi_def_cfa_offset 24
    #.cfi_restore %r13

    # Restore R12
    popq %r12
    #.cfi_def_cfa_offset 16
    #.cfi_restore %r12

    # Restore RBX
    popq %rbx
    #.cfi_def_cfa_offset 8
    #.cfi_restore %rbx

    CRUMB 2002
    CHECK_CALLEE_SAVED 9003             # Check callee-saved before return
    SNAPSHOT test_restore_done, capture_restore

    # Pop the fake frame (8 bytes: synthetic frame), otherwise we run user code twice
    addq $8, %rsp

    # RSP is ALREADY pointing to the return address.
    # We do NOT push %rax. Just return.
    ret
    .cfi_endproc

handle_overflow_error:
    # We are currently on the Safe Stack (Emergency Stack).
    # We can safely call a logging function or scheduler kill function.

    # We need to clean up the stack (pops) before jumping?
    # Actually, if we are killing the fiber, we don't care about these registers.
    # Just align the stack and call the panic handler.
    andq $-16, %rsp
    CHECK_ALIGN 9900
    call __zig_stack_overflow_handler

panic_stack_depth_mismatch:
    movq $9998, %rdi
    call abi_panic

panic_alignment_mismatch:
    movq $9999, %rdi
    call abi_panic

.global test_before_switch
test_before_switch:
    nop

.global test_restore_done
test_restore_done:
    nop


.size test_stack_switch, .-test_stack_switch



.text
.global victim_func
.type victim_func, @function
victim_func:
    .cfi_startproc
    # 1. Injection Prologue: Switch Stacks
    #    This simulates the LLVM pass insertion.
    call __morestack

    # --- WE ARE NOW ON THE NEW STACK ---
    # The return address on the stack points to 'restore_stack'

    # 2. Standard Prologue (Happens ON THE NEW STACK)
    #    This aligns RSP from ...8 to ...0.
    pushq %rbp
    movq %rsp, %rbp

    # 3. The Body
    #    We are now 16-byte aligned. Safe to call Zig/C functions.
    CRUMB 3000

    # Verify RDI (Arg 1) AND RSI (Arg 2) survived
    # 3. Verify ALL registers survived the wormhole
    movq %rdi, %rax    # rax = 7
    addq %rsi, %rax    # rax = 42
    addq %rdx, %rax    # rax = 142
    addq %rcx, %rax    # rax = 1142
    addq %r8,  %rax    # rax = 11142
    addq %r9,  %rax    # rax = 111142

    # 5. Standard Epilogue
    popq %rbp

    # 6. Return
    #    This executes 'ret'.
    #    Because 'test_stack_switch' set up the stack, this 'ret'
    #    actually jumps to 'restore_stack'.
    ret
    .cfi_endproc

    # 7. What happens nex:
    #    - execution jumps to 'restore_stack'
    #    - 'restore_stack' pops registers (RBX, R12-R15, RBP)
    #    - 'restore_stack' switches RSP back to the old stack
    #    - 'restore_stack' executes 'ret'
    #
    #    Because 'restore_stack' NEVER touches %rax,
    #    it is still there when control returns to the Zig Test Caller.

.text
.global run_stack_stitch_harness
.type run_stack_stitch_harness, @function
run_stack_stitch_harness:
    .cfi_startproc

    movq $7, %rdi      # Arg 1
    movq $35, %rsi     # Arg 2
    movq $100, %rdx    # Arg 3
    movq $1000, %rcx   # Arg 4
    movq $10000, %r8   # Arg 5
    movq $100000, %r9  # Arg 6

    call victim_func

    # %rax should be 111142
    ret
    .cfi_endproc

