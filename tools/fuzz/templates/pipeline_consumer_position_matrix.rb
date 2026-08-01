# Template: pipeline consumer POSITION matrix.
#
# The other pipeline templates pin the position and vary the operator, the
# source shape, or the element expression. This one does the opposite: it
# fixes two representative operators -- one producing owned elements
# (SELECT dup(_)), one producing borrowed elements (WHERE) -- and varies
# WHERE THE RESULT LANDS. That axis is what decides frame rewind and escape
# promotion for a pipeline temporary: a result bound inside a FOR/WHILE body
# needs per-iteration rewind, one bound in a MATCH arm inside a loop must
# still be visible to that rewind synthesis, and one handed to TAKES / a
# struct field / an outer list must promote at declaration instead of
# escaping a rewound frame.
#
# Scalar terminals get the same treatment for their accumulator: an owned
# REDUCE accumulator rebuilt every iteration of an enclosing loop is a
# distinct cleanup shape from the same terminal at top level.

PIPELINE_CONSUMER_POSITION_CELLS = []

%i[select_owned where_borrow].each do |op|
  %i[
    local_in_for local_in_while local_in_match_for foreach_in_if if_cond
    mid_where mid_select_owned push_outer struct_field arg_takes arg_borrow
  ].each do |position|
    PIPELINE_CONSUMER_POSITION_CELLS << { op: op, position: position }
  end
end

%i[reduce_owned join_owned].each do |op|
  %i[in_for in_while].each do |position|
    PIPELINE_CONSUMER_POSITION_CELLS << { op: op, position: position }
  end
end

PCPM_PRELUDE = <<~CHT
  ENUM Mode { A, B }
  STRUCT Holder { items: String[] }

  FN dup(s: String) RETURNS String -> RETURN COPY s; END

  FN takeStrs(ys: String[]) RETURNS Int64 -> RETURN ys.length(); END
  FN sinkStrs(TAKES ys: String[]) RETURNS Int64 -> RETURN ys.length(); END
CHT

def pcpm_frag(op)
  case op
  when :select_owned then "xs |> SELECT dup(_)"
  when :where_borrow then "xs |> WHERE !(_.empty?())"
  when :reduce_owned then "xs |> REDUCE(\"\") acc $+ _"
  when :join_owned   then "(xs |> WHERE !(_.empty?())).join(\",\")"
  end
end

# Body of `FN f(xs: String[]) RETURNS Int64`. Every body returns a
# non-negative count so `main` can assert on it without depending on which
# operator produced the list.
def pcpm_body(op, position)
  frag = pcpm_frag(op)
  case position
  when :local_in_for
    "MUTABLE n: Int64 = 0_i64;\n  FOR i IN [1_i64, 2_i64] DO\n    ys = #{frag};\n    n = n + ys.length();\n  END\n  RETURN n;"
  when :local_in_while
    "MUTABLE n: Int64 = 0_i64;\n  MUTABLE i: Int64 = 0_i64;\n  WHILE i < 2_i64 DO\n    ys = #{frag};\n    n = n + ys.length();\n    i = i + 1_i64;\n  END\n  RETURN n;"
  when :local_in_match_for
    "m: Mode = Mode.A;\n  MUTABLE n: Int64 = 0_i64;\n  FOR i IN (1_i64..=2_i64) DO\n" \
    "    PARTIAL MATCH m START\n        Mode.A ->\n          ys = #{frag};\n          n = n + ys.length();,\n" \
    "        DEFAULT -> n = n + 0_i64;\n    END\n  END\n  RETURN n;"
  when :foreach_in_if
    "MUTABLE n: Int64 = 0_i64;\n  IF xs.length() > 0_i64 THEN\n    FOR e IN #{frag} DO\n      n = n + e.length();\n    END\n  END\n  RETURN n;"
  when :if_cond
    "IF (#{frag}).length() > 0_i64 THEN\n    RETURN 1_i64;\n  END\n  RETURN 0_i64;"
  when :mid_where
    "ys = #{frag} |> WHERE !(_.empty?());\n  RETURN ys.length();"
  when :mid_select_owned
    "ys = #{frag} |> SELECT dup(_);\n  RETURN ys.length();"
  when :push_outer
    "MUTABLE all: String[][] = List[];\n  &all.push(#{frag});\n  RETURN all.length();"
  when :struct_field
    "h = Holder{ items: #{frag} };\n  RETURN h.items.length();"
  when :arg_takes
    "RETURN sinkStrs(#{frag});"
  when :arg_borrow
    "RETURN takeStrs(#{frag});"
  when :in_for
    "MUTABLE n: Int64 = 0_i64;\n  FOR i IN [1_i64, 2_i64] DO\n    v = #{frag};\n    n = n + v.length();\n  END\n  RETURN n;"
  when :in_while
    "MUTABLE n: Int64 = 0_i64;\n  MUTABLE i: Int64 = 0_i64;\n  WHILE i < 2_i64 DO\n    v = #{frag};\n    n = n + v.length();\n    i = i + 1_i64;\n  END\n  RETURN n;"
  end
end

FuzzGenerator.register(:pipeline_consumer_position_matrix,
                       cells: PIPELINE_CONSUMER_POSITION_CELLS) do |p|
  <<~CHT
    #{PCPM_PRELUDE}
    FN f(xs: String[]) RETURNS Int64 ->
      #{pcpm_body(p[:op], p[:position])}
    END

    FN main() RETURNS Void ->
        ASSERT f(["a:b", "c"]) >= 0_i64, "pipeline consumer position";
        RETURN;
    END
  CHT
end
