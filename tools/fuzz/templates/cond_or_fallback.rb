# Template: `(maybe(...) OR fallback) <cmp> baseline` in a control-flow
# condition. Surfaces the lower_if hoist-ordering bug catalogued in
# docs/agents/clear-bug123-forensic.md #1.
#
# The shape that triggers the bug is:
#   FN maybe(s: String) RETURNS !String ->
#     IF s.length() == 0 THEN RAISE "empty"; END    # explicit RAISE
#     RETURN COPY s;                                 # heap-allocating return
#   END
#   FN main() RETURNS !Void ->
#     IF (maybe("X") OR "") != "X" THEN RAISE "..."; END
#   END
#
# The result of `maybe(...) OR ""` is heap-allocated (because maybe's
# success path COPYs into a heap dupe and OR's fallback is the literal
# ""), so `hoist_alloc` lifts it into a `__tmp_N` Let. The Let is pushed
# to `@pending_stmts`. lower_if then calls `lower_body(then_branch)`,
# which flushes that pending Let INTO the then-body, before the cond's
# `__tmp_N` reference can ever see it. Zig rejects with
# "use of undeclared identifier '__tmp_N'".
#
# Cell schema:
#   { container:  :if  | :while,        # control-flow node holding the cond
#     fallback:   :empty | :default,    # value to fall back to on raise
#     value_type: :heap_string | :heap_list }
#
# Today every cell fails. Once lower_if isolates cond pending stmts (see
# the forensic), all cells turn green.

COND_OR_FALLBACK_CELLS = []
[:if, :while].each do |ctr|
  [:empty, :default].each do |fb|
    [:heap_string, :heap_list].each do |vt|
      COND_OR_FALLBACK_CELLS << { container: ctr, fallback: fb, value_type: vt }
    end
  end
end

def cof_value_type(t)
  case t
  when :heap_string then "String"
  when :heap_list   then "Int64[]@list"
  end
end

def cof_fallback_literal(fb, t)
  return "\"\""    if fb == :empty   && t == :heap_string
  return "\"x\""   if fb == :default && t == :heap_string
  return "[]"      if fb == :empty   && t == :heap_list
  "[1_i64, 2_i64]" if fb == :default && t == :heap_list
end

def cof_baseline(t)
  case t
  when :heap_string then "\"baseline\""
  when :heap_list   then "[42_i64]"
  end
end

def cof_inner_fn(t)
  ret_t = cof_value_type(t)
  case t
  when :heap_string
    <<~CHT.chomp
      FN maybe(s: String) RETURNS !#{ret_t} ->
          IF s.length() == 0 THEN RAISE "empty"; END
          RETURN COPY s;
      END
    CHT
  when :heap_list
    # COPY a list arg to force heap allocation. The conditional RAISE on
    # an impossible path tags the function as :explicit-raise fallible,
    # which is what the caller's hoist treats as heap-provenance.
    <<~CHT.chomp
      FN maybe(xs: Int64[]@list) RETURNS !#{ret_t} ->
          IF length(xs) < 0_i64 THEN RAISE "impossible"; END
          RETURN COPY xs;
      END
    CHT
  end
end

def cof_call_arg(t)
  case t
  when :heap_string then "\"X\""
  when :heap_list   then "[7_i64]"
  end
end

def cof_compare(t, expr, baseline)
  # Use the comparison primitive that exists for the type. != for strings
  # and a length comparison for lists (CLEAR doesn't have a primitive
  # element-by-element compare for `@list`).
  case t
  when :heap_string then "(#{expr}) != #{baseline}"
  when :heap_list   then "length(#{expr}) != length(#{baseline})"
  end
end

def cof_container_block(p, cond, body)
  case p[:container]
  when :if
    "IF #{cond} THEN\n        #{body}\n    END"
  when :while
    # Bound by an unrelated counter so the loop terminates. The cond's
    # OR-fallback expression is the second clause; both halves must
    # short-circuit before the loop exits.
    <<~BODY.chomp
      MUTABLE iter: Int64 = 0_i64;
          WHILE iter < 3_i64 && #{cond} DO
              iter = iter + 1_i64;
              #{body}
          END
    BODY
  end
end

FuzzGenerator.register(:cond_or_fallback, cells: COND_OR_FALLBACK_CELLS) do |p|
  inner_fn = cof_inner_fn(p[:value_type])
  arg      = cof_call_arg(p[:value_type])
  fb_lit   = cof_fallback_literal(p[:fallback], p[:value_type])
  baseline = cof_baseline(p[:value_type])
  expr     = "maybe(#{arg}) OR #{fb_lit}"
  cond     = cof_compare(p[:value_type], expr, baseline)
  body     = "RAISE \"cond_or_fallback_body\";"
  block    = cof_container_block(p, cond, body)

  <<~CHT
    #{inner_fn}

    FN main() RETURNS !Void ->
        #{block}
        RETURN;
    END
  CHT
end
