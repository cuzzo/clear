# Template: `expr OR <action>` in every syntactic position.
#
# Bug #10 in formal-verification-bugs.md: `result = run() OR PASS;`
# leaks when run() returns a heap-allocated value. The cleanup defer
# for `result` doesn't get attached. The fuzz hypothesis is that
# `OR <action>` lowering paths each have their own cleanup logic, and
# the pairing is position-specific — so the bug surface is wider than
# just assignment-RHS.
#
# This matrix exercises every position OR can appear in × every action ×
# both success and failure of the inner expression.
#
# Cell schema:
#   { position:, action:, outcome:, inner_t: }
#
#   position ∈ {
#     :assign_rhs,    # x = expr OR action
#     :fn_arg,        # consume(expr OR action)
#     :method_arg,    # outer.append(expr OR action)
#     :return_expr,   # RETURN expr OR action
#     :with_source,   # WITH EXCLUSIVE (expr OR action) AS x { ... }
#     :collection_lit,# [expr OR action]
#   }
#
#   action  ∈ {:pass, :raise, :default}
#   outcome ∈ {:success, :raise}            # whether inner raises
#   inner_t ∈ {:heap_list, :heap_string}    # both heap to maximize leak signal

OR_POSITIONS = [:assign_rhs, :fn_arg, :method_arg, :return_expr,
                :with_source, :collection_lit]
OR_ACTIONS   = [:pass, :raise, :default]
OR_OUTCOMES  = [:success, :raise]
OR_INNER_TS  = [:heap_list, :heap_string]

OR_POSITIONAL_CELLS = []
OR_POSITIONS.each do |pos|
  OR_ACTIONS.each do |act|
    OR_OUTCOMES.each do |out|
      OR_INNER_TS.each do |t|
        # OR RAISE in :raise outcome propagates and exits non-zero — that
        # masks leak detection. Skip; the other actions cover the path.
        next if act == :raise && out == :raise
        OR_POSITIONAL_CELLS << { position: pos, action: act, outcome: out, inner_t: t }
      end
    end
  end
end

# ── helpers ───────────────────────────────────────────────────────────

def or_inner_value_type(t)
  case t
  when :heap_list   then "Int64[]@list"
  when :heap_string then "String"
  end
end

def or_outer_list_type(t)
  case t
  when :heap_list   then "Int64[][]@list"
  when :heap_string then "String[]@list"
  end
end

def or_inner_default(t)
  case t
  when :heap_list   then "[]"
  when :heap_string then "\"\""
  end
end

def or_inner_construct(t)
  case t
  when :heap_list   then "MUTABLE v: Int64[]@list = []; v.append(1_i64);"
  when :heap_string then "MUTABLE v: String = \"\"; v = v + \"x\";"
  end
end

def or_inner_fn(t, raises:)
  ret_t = or_inner_value_type(t)
  body  = or_inner_construct(t)
  raise_line = raises ? "RAISE;" : "RETURN v;"
  <<~CHT.chomp
    FN inner() RETURNS !#{ret_t} ->
        #{body}
        #{raise_line}
    END
  CHT
end

def or_action_text(action, t)
  case action
  when :pass    then "PASS"
  when :raise   then "RAISE"
  when :default then or_inner_default(t)
  end
end

# Build the body of the run() function for the cell.
def or_body(p)
  vt   = or_inner_value_type(p[:inner_t])
  act  = or_action_text(p[:action], p[:inner_t])
  expr = "inner() OR #{act}"

  case p[:position]
  when :assign_rhs
    "MUTABLE result: #{vt} = #{expr};"
  when :fn_arg
    # consume(...) accepts a value of type vt and returns Int64 length.
    "MUTABLE len: Int64 = consume(#{expr});"
  when :method_arg
    # method-arg position: append a heap-allocated value into outer list.
    "MUTABLE outer: #{or_outer_list_type(p[:inner_t])} = []; outer.append(#{expr});"
  when :return_expr
    # The OR expression IS the function's return; signature differs from
    # other positions. Caller binds the result.
    "RETURN #{expr};"
  when :with_source
    # WITH source — wrap expr in @locked so WITH EXCLUSIVE has a target.
    "MUTABLE container = (#{expr}) @locked; WITH EXCLUSIVE container AS x { _ = #{x_use(p[:inner_t])}; }"
  when :collection_lit
    "MUTABLE items: #{or_outer_list_type(p[:inner_t])} = [#{expr}];"
  end
end

def x_use(t)
  case t
  when :heap_list   then "length(x)"
  when :heap_string then "x.length()"
  end
end

# What return type run() needs depends on the position.
def or_run_signature(p)
  vt = or_inner_value_type(p[:inner_t])
  rt = case p[:position]
       when :return_expr then vt
       else "Void"
       end
  "FN run() RETURNS !#{rt} ->"
end

# consume helper for fn_arg cells. Takes the value, returns its length so
# the caller can bind to Int64.
def or_consume_helper(t)
  case t
  when :heap_list
    "FN consume(TAKES xs: Int64[]@list) RETURNS Int64 -> RETURN length(xs); END"
  when :heap_string
    "FN consume(TAKES s: String) RETURNS Int64 -> RETURN s.length(); END"
  end
end

FuzzGenerator.register(:or_positional, cells: OR_POSITIONAL_CELLS) do |p|
  raises = (p[:outcome] == :raise)
  inner_fn = or_inner_fn(p[:inner_t], raises: raises)
  body = or_body(p)
  signature = or_run_signature(p)

  helpers = (p[:position] == :fn_arg) ? or_consume_helper(p[:inner_t]) + "\n\n" : ""

  <<~CHT
    #{helpers}#{inner_fn}

    #{signature}
        #{body}
        #{p[:position] == :return_expr ? '' : 'RETURN;'}
    END

    FN main() RETURNS Void ->
        run() OR PASS;
        RETURN;
    END
  CHT
end
