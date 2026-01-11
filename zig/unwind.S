.text
.cfi_sections .eh_frame

.data
.align 64
# Ensure visibility is restricted to prevent name collisions
.global breadcrumb_counter
breadcrumb_counter:
    .quad 0

.global breadcrumbs
breadcrumbs:
    .zero 8000

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


# CFI only necessary when moving rsp or rbp
# OR callee-saved registers: %rbx, %r12-%r15
# NOT: %rax, %rdx, %rdi, %r8-%r11
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

