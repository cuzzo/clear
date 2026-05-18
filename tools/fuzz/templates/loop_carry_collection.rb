# Template: collection built inside a loop and used after the loop.
# Stresses E2 :loop_carry_string and the loop-escape promotion path
# (recent commits 9fa21926, d80e6539, 1599bfb1).
#
# Pattern: declare a list, push to it inside a loop, then read
# length/contents after the loop. Loop-local mark/rewind must NOT free
# the list's backing buffer (it lives in the enclosing frame, not the
# loop's per-iter frame).
#
# Axes:
#   elem    : Int64 / String element type
#   depth   : 1 = single loop, 2 = nested loops (flat carrier only)
#   outer   : iteration count
#   carrier : :flat   -> `T[]@list`
#             :nested -> `H[]@list` where `STRUCT H { values: T[]@list }`,
#                        with a NESTED-FIELD append `lst[i].values.append`
#   body    : :plain       -> body only appends
#             :frame_alloc -> body declares a per-iteration frame @list,
#                             forcing the non-tight loop's
#                             saveLoopMark/restoreLoopMark (mark_per_iter)
#
# The `:nested` + `:frame_alloc` cells are the regression for the
# nested-@list-field-append allocator bug (docs/agents/vm-bugs.md
# "nested-@list-field append allocator not inherited from root
# container"): the per-iteration arena rewind promotes the root
# container to :heap; the nested-field append must inherit that root
# allocator, not resolve :frame from the leaf GetField/GetIndex
# receiver. Pre-fix these cells fail with INLINE_ALLOC_MISMATCH;
# post-fix the whole matrix is clean. The original flat/:plain cells
# never exercised this (no nested-field carrier, no frame-alloc body)
# -- the template was partially implemented.

LOOP_CARRY_CELLS = []

# Original coverage: flat carrier, plain body.
[:int, :string].each do |elem|
  [1, 2].each do |depth|
    [5, 12].each do |outer|
      LOOP_CARRY_CELLS << { elem: elem, depth: depth, outer: outer,
                            carrier: :flat, body: :plain }
    end
  end
end

# Bug regression: nested-@list-field carrier with a frame-allocating
# non-tight loop body (depth 1 is the minimal triggering shape).
[:int, :string].each do |elem|
  [5, 12].each do |outer|
    LOOP_CARRY_CELLS << { elem: elem, depth: 1, outer: outer,
                          carrier: :nested, body: :frame_alloc }
  end
end

FuzzGenerator.register(:loop_carry_collection, cells: LOOP_CARRY_CELLS) do |p|
  zig_type  = (p[:elem] == :int) ? "Int64" : "String"
  push_expr = (p[:elem] == :int) ? "i" : "i.toString()"

  if p[:carrier] == :nested
    # Non-tight WHILE; per-iter frame @list (scratch) -> mark_per_iter;
    # nested-field append lst[i].values.append(scratch[0]).
    <<~CHT
      STRUCT H { values: #{zig_type}[]@list }

      FN main() RETURNS Void ->
          MUTABLE lst: H[]@list = [];
          MUTABLE i: Int64 = 0_i64;
          WHILE i < #{p[:outer]}_i64 DO
              MUTABLE scratch: #{zig_type}[]@list = List[];
              scratch.append(#{push_expr});
              lst.append(H{ values: [] });
              lst[i].values.append(COPY scratch[0]);
              i = i + 1_i64;
          END
          MUTABLE total: Int64 = 0_i64;
          FOR h IN (0_i64 ..< length(lst)) DO
              total = total + length(lst[h].values);
          END
          ASSERT total == #{p[:outer]}_i64, "nested-field appends after loop";
          RETURN;
      END
    CHT
  else
    type_decl = "#{zig_type}[]@list"
    inner = case p[:depth]
    when 1
      "    FOR i IN (1_i64 ..= #{p[:outer]}_i64) DO\n        lst.append(#{push_expr});\n    END"
    when 2
      inner_count = 3
      if p[:elem] == :int
        <<~BODY.chomp
              FOR i IN (1_i64 ..= #{p[:outer]}_i64) DO
                  FOR j IN (1_i64 ..= #{inner_count}_i64) DO
                      lst.append(i + j);
                  END
              END
        BODY
      else
        <<~BODY.chomp
              FOR i IN (1_i64 ..= #{p[:outer]}_i64) DO
                  FOR j IN (1_i64 ..= #{inner_count}_i64) DO
                      lst.append(j.toString());
                  END
              END
        BODY
      end
    end

    expected_len = (p[:depth] == 1) ? p[:outer] : p[:outer] * 3

    <<~CHT
      FN main() RETURNS Void ->
          MUTABLE lst: #{type_decl} = [];
      #{inner}
          ASSERT length(lst) == #{expected_len}_i64, "list length after loop";
          RETURN;
      END
    CHT
  end
end
