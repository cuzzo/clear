# Template: fallible-signature discipline (`RETURNS T` vs `RETURNS !T`).
#
# Invariant under test:
#   A function's declared return type must be an error union (`!T`)
#   *iff* the function genuinely propagates a failure to its caller.
#   ALLOCATION ALONE IS NOT FAILURE. CLEAR's arena model bump-allocates
#   and panics on OOM; it does not return an error union for `charAt`,
#   `split`, string concat, list build, or a heap-shaped return value.
#
# This is the root cause of docs/agents/puck-clear-bugs.md #3: the
# annotator conflates "uses frame/heap/alloc" with "raises" in the
# single `@fn_raises_directly` flag (src/annotator.rb:779), so every
# string-touching function with a plain `RETURNS T` is wrongly forced
# to `RETURNS !T` with the misleading diagnostic "raises directly via
# RAISE".
#
# The matrix is exhaustive over the three things that determine the
# correct signature:
#
#   fail_source  -- what (if anything) in the body produces failure
#   decl         -- how the author declared the return type
#   ret_shape    -- the value shape returned (scalar vs heap), so the
#                    return-path allocation axis is covered too
#
# Oracle:
#   true_fallible := fail_source propagates an error out of the fn
#                    (:direct_raise, :or_raise_builtin,
#                     :fallible_callee_propagated)
#   infallible    := everything else, INCLUDING every :alloc_* source
#                    and :fallible_callee_absorbed (the OR-fallback /
#                    absorbed-callee cases) and :none.
#
#   decl :plain        + infallible      -> :pass
#       (THE bug-#3 class: must compile. Pre-fix the compiler wrongly
#        rejects every :alloc_* / heap-return cell here.)
#   decl :plain        + true_fallible   -> :compile_error
#       (under-declared: the compiler MUST reject — Zig-style discipline.)
#   decl :error_union  + true_fallible   -> :pass
#   decl :error_union  + infallible      -> :pass
#       (over-declaring `!T` for a fn that never fails is legal — same
#        as every `FN main() RETURNS !Void` that just `RETURN`s.)
#
# Cell schema:
#   { fail_source: Symbol, decl: :plain|:error_union,
#     ret_shape: :scalar|:heap_string|:heap_list, expected: ... }

INFALLIBLE_SIG_FAIL_SOURCES = %i[
  none
  alloc_string_literal
  alloc_charAt
  alloc_split
  alloc_concat
  alloc_list_build
  direct_raise
  or_raise_builtin
  fallible_callee_propagated
  fallible_callee_absorbed
].freeze

INFALLIBLE_SIG_TRUE_FALLIBLE = %i[
  direct_raise
  or_raise_builtin
  fallible_callee_propagated
].freeze

INFALLIBLE_SIG_CELLS = []
INFALLIBLE_SIG_FAIL_SOURCES.each do |fs|
  %i[plain error_union].each do |decl|
    %i[scalar heap_string heap_list].each do |ret|
      true_fallible = INFALLIBLE_SIG_TRUE_FALLIBLE.include?(fs)
      # ERROR-vs-FAULT oracle (the unified alloc-as-FAULT model;
      # puck-clear-bugs.md #3/#10/#12/#13):
      #   - GENUINE ERROR (RAISE / OR RAISE / propagated ERROR callee)
      #     with a plain `RETURNS T` is UNDER-DECLARED -> :compile_error
      #     (surface enforcement: errors must be in the type).
      #   - Everything else compiles. An allocating FAULT source
      #     (none/alloc_*) with `RETURNS T` is LEGAL: the fn rides the
      #     uniform Zig !T pipeline (alloc_fault -> can_fail) but is
      #     surface-exempt; unhandled OOM panics (System/OutOfMemory),
      #     catchable anywhere via OR/CATCH. fallible_callee_absorbed
      #     stays infallible (#11). All ret_shapes incl heap_list now
      #     transpile (6a: declared-collection-return -> alloc_fault ->
      #     Zig `!`). No :in_dev parks remain -- the gate is now the
      #     full regression oracle for the model.
      expected =
        if decl == :plain && true_fallible
          :compile_error            # ERROR under-declared, must reject
        else
          :pass                     # FAULT/declared-error: must compile
        end
      INFALLIBLE_SIG_CELLS << {
        fail_source: fs, decl: decl, ret_shape: ret, expected: expected
      }
    end
  end
end

def isig_ret_type(ret)
  case ret
  when :scalar      then "Int64"
  when :heap_string then "String"
  when :heap_list   then "Int64[]@list"
  end
end

def isig_decl_type(decl, ret)
  t = isig_ret_type(ret)
  decl == :error_union ? "!#{t}" : t
end

# The value the subject returns on its normal (only) path. Deterministic
# so the :pass cells produce a checkable result at runtime.
def isig_retval(ret)
  case ret
  when :scalar      then "7_i64"
  when :heap_string then "\"ok\""
  when :heap_list   then "[1_i64]"
end
end

def isig_assert(ret)
  case ret
  when :scalar      then "ASSERT r == 7_i64, \"isig scalar\";"
  when :heap_string then "ASSERT r.length() == 2_i64, \"isig string\";"
  when :heap_list   then "ASSERT r.length() == 1_i64, \"isig list\";"
  end
end

# Body fragment that introduces the fail_source.
#
# CRITICAL: the infallible sources must contain ZERO `RAISE`/`OR RAISE`
# /propagation -- the whole point of bug #3 is that ALLOCATION ALONE
# (no failure path) wrongly forces `!T`. The guard uses an impossible
# `== 999` comparison and a plain `RETURN <retval>` (a RETURN is not a
# failure), so the binding is used (no unused-var warning), the
# allocation is statically present, and the cell still falls through to
# the final RETURN deterministically at runtime.
#
# Only the three INFALLIBLE_SIG_TRUE_FALLIBLE sources emit a real
# RAISE / OR RAISE / propagated callee error.
def isig_body(fs, retval)
  case fs
  when :none
    ""
  when :alloc_string_literal
    %(    lit = "abcd";\n    IF lit.length() == 999_i64 THEN RETURN #{retval}; END\n)
  when :alloc_charAt
    %(    ch = a.charAt(0_i64) OR "";\n    IF ch.length() == 999_i64 THEN RETURN #{retval}; END\n)
  when :alloc_split
    %(    parts = a.split(" ");\n    IF parts.length() == 999_i64 THEN RETURN #{retval}; END\n)
  when :alloc_concat
    %(    cat = a + a;\n    IF cat.length() == 999_i64 THEN RETURN #{retval}; END\n)
  when :alloc_list_build
    %(    MUTABLE xs: Int64[]@list = [];\n    xs.append(3_i64);\n    IF xs.length() == 999_i64 THEN RETURN #{retval}; END\n)
  when :direct_raise
    # Statically a RAISE path; the guard is impossible at runtime.
    %(    IF a.length() == 999_i64 THEN RAISE "never"; END\n)
  when :or_raise_builtin
    # Propagate a builtin-fallible op's failure via OR RAISE.
    %(    ch = a.charAt(0_i64) OR RAISE;\n    IF ch.length() == 999_i64 THEN RETURN #{retval}; END\n)
  when :fallible_callee_propagated
    # Call a `RETURNS !String` helper and propagate its error.
    %(    h = isigFlaky(a) OR RAISE;\n    IF h.length() == 999_i64 THEN RETURN #{retval}; END\n)
  when :fallible_callee_absorbed
    # Call the same helper but ABSORB the error -> subject infallible.
    %(    h = isigFlaky(a) OR "fallback";\n    IF h.length() == 999_i64 THEN RETURN #{retval}; END\n)
  end
end

# Emitted once per program; only referenced by the callee-based sources
# but harmless (and unused-fn is not an error) otherwise.
ISIG_HELPER = <<~CHT.chomp
  FN isigFlaky(s: String) RETURNS !String ->
      IF s.length() == 999_i64 THEN RAISE "flaky"; END
      RETURN COPY s;
  END
CHT

FuzzGenerator.register(:infallible_signature, cells: INFALLIBLE_SIG_CELLS) do |p|
  ret_decl = isig_decl_type(p[:decl], p[:ret_shape])
  retval   = isig_retval(p[:ret_shape])
  body     = isig_body(p[:fail_source], retval)
  # main consumes the subject's error iff the subject is declared !T.
  consume  = p[:decl] == :error_union ? " OR RAISE" : ""
  assert   = isig_assert(p[:ret_shape])

  <<~CHT
    #{ISIG_HELPER}

    FN isigSubject(a: String) RETURNS #{ret_decl} ->
    #{body}    RETURN #{retval};
    END

    FN main() RETURNS !Void ->
        r = isigSubject("hello")#{consume};
        #{assert}
        RETURN;
    END
  CHT
end
