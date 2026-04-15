#.text
#.cfi_sections .eh_frame


# Assumes 16-byte alignment (standard for function bodies after prologue)
.text
.macro CRUMB id
    pushfq
    pushq %rax
    pushq %rdx
    pushq %rdi

    # 2. Update Global Counter safely using PC-relative addressing
    # We get the address of the pointer from the GOT
    movq breadcrumb_counter@GOTPCREL(%rip), %rax
    movq (%rax), %rdx  # Current count in rdx

    movq breadcrumbs@GOTPCREL(%rip), %rdi
    movq $\id, (%rdi, %rdx, 8)

    incq %rdx
    movq %rdx, (%rax)

    # 3. Call the Dumper
    # Stack is currently aligned to 16 bytes.
    movq $\id, %rdi
    call dump_unwind_safe
    test %rax, %rax
    jnz 1f

    # 4. Restore
    popq %rdi
    popq %rdx
    popq %rax
    popfq

    jmp 2f

# Unwind Entry / Sad Path
1:
    addq $24, %rsp    # Clean stack
    popfq

    # Instead of jumping to a label in the function,
    # we handle the "return" right here for the test.
    leave             # Note: %rax still contains the error code (1)
    ret

# Happy Path
2:
.endm

.macro CHECK_ERR
    testq %rax, %rax
    jz .L_check_done_\@   # Unique label per expansion
    leave
    ret
.L_check_done_\@:
.endm

# --- THE DUMPER ---
.global dump_unwind_safe
.type dump_unwind_safe, @function
dump_unwind_safe:
    .cfi_startproc
    pushq %rbp
    .cfi_adjust_cfa_offset 8
    .cfi_offset %rbp, -16
    movq %rsp, %rbp
    .cfi_def_cfa_register %rbp

    subq $1024, %rsp
    andq $-64, %rsp

    movq %rsp, %rdi
    call unw_getcontext

    movq %rsp, %rdi
    call zig_dump_from_context

    leave
    .cfi_restore %rbp
    .cfi_def_cfa %rsp, 8
    ret
    .cfi_endproc
.size dump_unwind_safe, .-dump_unwind_safe

# --- THE TEST CHAIN ---
.global test_macro_chain
.type test_macro_chain, @function
test_macro_chain:
    .cfi_startproc
    pushq %rbp
    .cfi_adjust_cfa_offset 8
    .cfi_offset %rbp, -16
    movq %rsp, %rbp
    .cfi_def_cfa_register %rbp
    call func_a
    leave
    .cfi_restore %rbp
    .cfi_def_cfa %rsp, 8
    ret
    .cfi_endproc
.size test_macro_chain, .-test_macro_chain

# CRITICAL: Added .global here
.global func_a
.type func_a, @function
func_a:
    .cfi_startproc
    pushq %rbp
    .cfi_adjust_cfa_offset 8
    .cfi_offset %rbp, -16
    movq %rsp, %rbp
    .cfi_def_cfa_register %rbp

    call func_b
    CHECK_ERR

    # Happy Path
    leave
    ret
    .cfi_endproc
.size func_a, .-func_a


# CFI either anchored to rsp or rpb
# If anchored to rsp and rsp changes, must update
# If anchored to rpb and rpb changes, must update
# Do not need to update rsp if it changes when anchored to rpb (and vice versa).
#
# Need to update when callee-saved registers change: %rbx, %r12-%r15
# Do NOT need to update when volatile registers change: %rax, %rdx, %rdi, %r8-%r11
.global func_b
.type func_b, @function
func_b:
    .cfi_startproc
    pushq %rbp
    .cfi_adjust_cfa_offset 8
    .cfi_offset %rbp, -16
    movq %rsp, %rbp
    .cfi_def_cfa_register %rbp
    CRUMB 100

    # Happy path, CRUMB macros the sad path
    leave
    ret
    .cfi_endproc
.size func_b, .-func_b


#.section .bss
#test_stack: .space 65536  # 64KB fake stack



# 1 option is to manually manage the registers. It's ugly
.section .text
.global test_stack_unwind_bad
.type test_stack_unwind_bad, @function
test_stack_unwind_bad:
    .cfi_startproc
    # 1. SAVE R13 (Crucial! Zig crashes if you don't restore this)
    pushq %r13
    .cfi_adjust_cfa_offset 8
    .cfi_offset %r13, -16

    # 2. Setup the Pivot
    #    (Note: RSP changed by push, so we use the current RSP)
    movq %rsp, %r13
    .cfi_def_cfa_register 13

    # Move stack pointer!
    leaq test_stack + 4096(%rip), %rsp

    # 3. Call your dumper
    #    (If you uncomment the LEA later, do it here)
    call dump_unwind_safe

    # 4. RESTORE STACK
    #    Copy the original stack pointer back from our backup
    movq %r13, %rsp

    # 5. Restore State
    #    Reset DWARF to look at RSP again
    .cfi_def_cfa_register 7

    # 6. Restore R13 to its original value
    popq %r13
    .cfi_adjust_cfa_offset -8

    ret
    .cfi_endproc
.size test_stack_unwind_bad, .-test_stack_unwind_bad


.section .text
.global test_stack_unwind
.type test_stack_unwind, @function
test_stack_unwind:
    .cfi_startproc

    pushq %rbp
    .cfi_def_cfa_offset 16
    .cfi_offset %rbp, -16

    movq %rsp, %rbp
    .cfi_def_cfa_register %rbp

    # 2. SAVE R13 (Crucial!)
    #    We push this *inside* our new frame.
    #    Location: RBP - 8
    pushq %r13
    .cfi_offset %r13, -24

    # 3. SWITCH STACK
    #    We overwrite RSP.
    #    RBP is NOT touched, so it still points to the Old Stack.
    leaq test_stack + 4096(%rip), %rsp

    # 4. CALL DUMPER
    call dump_unwind_safe

    # 5. RESTORE STACK
    #    We cannot use 'mov %rbp, %rsp' yet, because R13 is sitting *below* RBP.
    #    We set RSP to RBP-8, which points exactly at our saved R13.
    leaq -8(%rbp), %rsp

    # 6. RESTORE REGISTERS
    popq %r13      # RSP now points to RBP
    popq %rbp      # RSP now points to Return Address

    ret
    .cfi_endproc
.size test_stack_unwind, .-test_stack_unwind


.data
.global entry_rbx
.global entry_rsp
.global entry_rbp
.global entry_r12
.global entry_r13
.global entry_r14
.global entry_r15
entry_rsp: .quad 0
entry_rbx: .quad 0
entry_rbp: .quad 0
entry_r12: .quad 0
entry_r13: .quad 0
entry_r14: .quad 0
entry_r15: .quad 0

.data
.align 64
# Ensure visibility is restricted to prevent name collisions
.global breadcrumb_counter
breadcrumb_counter:
    .quad 0

.global breadcrumbs
breadcrumbs:
    .zero 8000

