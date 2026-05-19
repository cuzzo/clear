# Template: caller-side heap-ownership transfer.
#
# THE surface the heap-ownership/cleanup collapse touches. "The caller
# received an owned heap value and must free it EXACTLY ONCE" is
# currently re-derived by 6+ passes (E1 return_expr_is_heap? AST
# allowlist, E2 heap_carry_return, E3a tag_transitive_provenance!,
# mark_heap_carry_call_sites!, PromotionClassifier, CleanupClassifier)
# from 6 different proxies. escape_via_return covers the callee
# value-SHAPE exhaustively but fixes the caller to `r = make()`. This
# template is the orthogonal axis the refactor must not regress:
#
#   ret_form  -- HOW the producer yields the value (which E1 proxy):
#                ident / literal / call (transitive) / give / field
#   bind_form -- HOW the caller consumes it (which E3a/discard/cleanup
#                path): bare / or_raise / or_fallback / discard /
#                discard_or_raise / onward (returned through a wrapper)
#   value     -- heap cleanup shape: list / string
#   decl      -- plain `RETURNS T` (FAULT/alloc) vs `RETURNS !T` (ERROR)
#
# Oracle: every cell must COMPILE, RUN, its ASSERT hold, and -- via the
# runner's aggregated DebugAllocator pass -- leak ZERO and double-free
# ZERO. Cells known-broken on the pre-refactor HEAD are marked :in_dev
# with the observed reason (so the baseline is green); the collapse
# refactor flips them to :pass with everything else still green.
#
# Every producer yields length 2 so the caller assert is uniform.

# [value, ret_form, bind_form, decl] tuples that FAIL on the
# pre-refactor HEAD (compile error / leak / double-free). Empirically
# harvested, not guessed. These are exactly the heap-ownership
# over-complexity manifesting; the collapse refactor must flip every
# one of them to :pass with zero regressions elsewhere.
HOT_KNOWN_FAILING = [].freeze

HOT_CELLS = []
%i[list string].each do |value|
  # Every producer genuinely allocates (list: append/makeList; string:
  # concat) so it is alloc-faultable -> can_fail -> the OR-bind forms
  # are valid for plain `RETURNS T` too (the FAULT is interceptable,
  # exactly like `risky() OR PASS`). `:give` is list-only (String is a
  # Copy type; GIVE moves non-Copy). `:field` (GetField return) is
  # dropped here -- escape_via_return's struct_with_list covers E1's
  # GetField branch callee-side and a valid in-template construct for
  # it conflates value-shape with the binding-form axis.
  ret_forms = value == :list ? %i[ident literal call give] : %i[ident literal call]
  ret_forms.each do |ret_form|
    %i[bare or_raise or_fallback discard discard_or_raise onward].each do |bind_form|
      %i[plain err].each do |decl|
        # `OR <value>` (orelse) needs a surface optional/error to
        # rescue. A FAULT (alloc) is NOT surface-visible on a plain
        # `RETURNS T` (that is the whole model), so `plain + or_fallback`
        # is model-invalid -- not a bug, an inexpressible combo. The
        # FAULT-interception path for plain producers is `OR PASS` /
        # `OR RAISE` (the :or_raise / :discard_or_raise cells), which
        # operate on the fault CHANNEL, not a surface optional.
        next if bind_form == :or_fallback && decl == :plain

        key = [value, ret_form, bind_form, decl]
        expected = HOT_KNOWN_FAILING.include?(key) ? :in_dev : :pass
        HOT_CELLS << { value: value, ret_form: ret_form,
                       bind_form: bind_form, decl: decl, expected: expected }
      end
    end
  end
end

def hot_type(value)
  value == :list ? "Int64[]@list" : "String"
end

def hot_decl_type(value, decl)
  t = hot_type(value)
  decl == :err ? "!#{t}" : t
end

# Length-2 producer value. BOTH allocate: list via append, string via
# concat (`"a" + "b"` -> std.mem.concat) so the producer is alloc-
# faultable in every form (uniform: all OR-bind forms valid).
def hot_build(value, var)
  if value == :list
    "    MUTABLE #{var}: Int64[]@list = [];\n    #{var}.append(1_i64);\n    #{var}.append(2_i64);\n"
  else
    "    #{var}: String = \"a\" + \"b\";\n"
  end
end

def hot_literal(value)
  value == :list ? "[1_i64, 2_i64]" : "\"a\" + \"b\""
end

def hot_fallback(value)
  value == :list ? "[]" : "\"\""
end

def hot_len_assert(value, rcv)
  value == :list ? "ASSERT length(#{rcv}) == 2_i64, \"hot len\";" \
                  : "ASSERT #{rcv}.length() == 2_i64, \"hot len\";"
end

# Producer `mk` body for the ret_form. `rt` = declared return type str.
def hot_producer(value, ret_form, rt)
  case ret_form
  when :ident
    "FN mk() RETURNS #{rt} ->\n#{hot_build(value, 'v')}    RETURN v;\nEND"
  when :literal
    "FN mk() RETURNS #{rt} ->\n    RETURN #{hot_literal(value)};\nEND"
  when :call
    inner = "FN mkInner() RETURNS #{rt} ->\n#{hot_build(value, 'v')}    RETURN v;\nEND"
    "#{inner}\n\nFN mk() RETURNS #{rt} ->\n    RETURN mkInner();\nEND"
  when :give
    "FN mk() RETURNS #{rt} ->\n#{hot_build(value, 'v')}    RETURN GIVE v;\nEND"
  end
end

# main() consuming mk() per bind_form. `mvoid` = main's return type.
def hot_main(value, bind_form, decl)
  fb = hot_fallback(value)
  case bind_form
  when :bare
    mret = decl == :err ? "!Void" : "Void"
    "FN main() RETURNS #{mret} ->\n    r = mk();\n    #{hot_len_assert(value, 'r')}\n    RETURN;\nEND"
  when :or_raise
    "FN main() RETURNS !Void ->\n    r = mk() OR RAISE;\n    #{hot_len_assert(value, 'r')}\n    RETURN;\nEND"
  when :or_fallback
    mret = decl == :err ? "!Void" : "Void"
    "FN main() RETURNS #{mret} ->\n    r = mk() OR #{fb};\n    RETURN;\nEND"
  when :discard
    mret = decl == :err ? "!Void" : "Void"
    "FN main() RETURNS #{mret} ->\n    _ = mk();\n    RETURN;\nEND"
  when :discard_or_raise
    "FN main() RETURNS !Void ->\n    _ = mk() OR RAISE;\n    RETURN;\nEND"
  when :onward
    # Wrapper returns mk() onward; main binds the wrapper.
    wret = decl == :err ? "!#{hot_type(value)}" : hot_type(value)
    w = "FN onward() RETURNS #{wret} ->\n    RETURN mk();\nEND"
    if decl == :err
      "#{w}\n\nFN main() RETURNS !Void ->\n    r = onward() OR RAISE;\n    #{hot_len_assert(value, 'r')}\n    RETURN;\nEND"
    else
      "#{w}\n\nFN main() RETURNS Void ->\n    r = onward();\n    #{hot_len_assert(value, 'r')}\n    RETURN;\nEND"
    end
  end
end

FuzzGenerator.register(:heap_ownership_transfer, cells: HOT_CELLS) do |p|
  rt = hot_decl_type(p[:value], p[:decl])
  producer = hot_producer(p[:value], p[:ret_form], rt)
  mainfn   = hot_main(p[:value], p[:bind_form], p[:decl])
  <<~CHT
    #{producer}

    #{mainfn}
  CHT
end
