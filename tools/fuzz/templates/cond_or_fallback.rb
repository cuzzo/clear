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
[:if, :while, :return].each do |ctr|
  [:empty, :default].each do |fb|
    [:heap_string, :heap_list].each do |value_type|
      cell = { container: ctr, fallback: fb, value_type: value_type }
      # Every cell is active. A condition-position OR fallback must either
      # compile correctly or expose a real regression.
      # :return cells exercise OR-fallback in RETURN position
      # (`RETURN maybe(x) OR fallback`) -- the escape analysis
      # return-value heap decision for BinaryOp/OR_RESCUE.
      cell[:expected] = :pass
      COND_OR_FALLBACK_CELLS << cell
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
  return "cofFallbackEmpty()" if fb == :empty && t == :heap_list
  "cofFallback()" if fb == :default && t == :heap_list
end

def cof_extra_fn(fb, t)
  return "" unless t == :heap_list

  return <<~CHT.chomp if fb == :empty
    FN cofFallbackEmpty() RETURNS Int64[]@list ->
        MUTABLE xs: Int64[]@list = [];
        RETURN xs;
    END
  CHT

  <<~CHT.chomp
    FN cofFallback() RETURNS Int64[]@list ->
        MUTABLE xs: Int64[]@list = [];
        xs.append(1_i64);
        xs.append(2_i64);
        RETURN xs;
    END
  CHT
end

def cof_baseline(t)
  # Must equal what `maybe(cof_call_arg)` returns on the success path so
  # the condition is FALSE and the RAISE body never runs — the cell is
  # testing the hoist, not actually raising. Mirrors the bug-1
  # reproducer, where `maybe("STRINGS")` is compared against "STRINGS".
  case t
  when :heap_string then "\"X\""        # == cof_call_arg(:heap_string)
  when :heap_list   then "List[7_i64]"  # == cof_call_arg(:heap_list)
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
  when :heap_list   then "List[7_i64]"
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
  when :return
    # OR-fallback in RETURN position is handled by a separate renderer
    # path; this block is unused for :return.
    ""
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
  extra_fn = cof_extra_fn(p[:fallback], p[:value_type])
  arg      = cof_call_arg(p[:value_type])
  fb_lit   = cof_fallback_literal(p[:fallback], p[:value_type])

  if p[:container] == :return
    # OR-fallback in RETURN position: a wrapper fn returns
    # `maybe(arg) OR fallback`. Exercises the return-value heap decision
    # for BinaryOp/OR_RESCUE in escape analysis.
    rt = cof_value_type(p[:value_type])
    param_t = cof_value_type(p[:value_type])
    next <<~CHT
      #{inner_fn}
      #{extra_fn}

      FN wrap(x: #{param_t}) RETURNS #{rt} ->
          RETURN maybe(x) OR #{fb_lit};
      END

      FN main() RETURNS Void ->
          ok = wrap(#{arg});
          ASSERT #{cof_compare(p[:value_type], 'ok', cof_call_arg(p[:value_type]))} == FALSE, "or-fallback in return";
          RETURN;
      END
    CHT
  end

  baseline = cof_baseline(p[:value_type])
  expr     = "maybe(#{arg}) OR #{fb_lit}"
  cond     = cof_compare(p[:value_type], expr, baseline)
  body     = "RAISE \"cond_or_fallback_body\";"
  block    = cof_container_block(p, cond, body)

  <<~CHT
    #{inner_fn}
    #{extra_fn}

    FN main() RETURNS !Void ->
        #{block}
        RETURN;
    END
  CHT
end
