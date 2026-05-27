# Template: collection built inside a loop and used after the loop.
# Stresses E2 :loop_carry_string and the loop-escape promotion path
# (recent commits 9fa21926, d80e6539, 1599bfb1).
#
# Pattern: declare a list, push to it inside a loop, then read
# length/contents after the loop. Loop-local mark/rewind must NOT free
# the list's backing buffer (it lives in the enclosing frame, not the
# loop's per-iter frame).
#
# Axes: elem {Int64,String} x depth x outer x carrier
# {:flat `T[]@list`, :nested `H{values:T[]@list}[]@list` with a
# nested-field append} x body {:plain, :frame_alloc (per-iter frame
# @list forcing the non-tight loop's saveLoopMark/restoreLoopMark)}.

LOOP_CARRY_CELLS = []

[:flat, :nested].each do |carrier|
  [:int, :string].each do |elem|
    [1, 2].each do |depth|
      [5, 12].each do |outer|
        [:plain, :frame_alloc].each do |body|
          LOOP_CARRY_CELLS << { elem: elem, depth: depth, outer: outer,
                                carrier: carrier, body: body }
        end
      end
    end
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
              #{p[:body] == :frame_alloc ? "MUTABLE scratch: #{zig_type}[]@list = List[];\n            scratch.append(#{push_expr});" : ""}
              lst.append(H{ values: [] });
              lst[i].values.append(#{p[:body] == :frame_alloc ? 'COPY scratch[0]' : push_expr});
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
    append_expr = if p[:body] == :frame_alloc
                    "MUTABLE scratch: #{zig_type}[]@list = List[];\n        scratch.append(#{push_expr});\n        lst.append(#{p[:elem] == :string ? 'COPY scratch[0]' : 'scratch[0]'});"
                  else
                    "lst.append(#{push_expr});"
                  end
    inner = case p[:depth]
    when 1
      "    FOR i IN (1_i64 ..= #{p[:outer]}_i64) DO\n        #{append_expr}\n    END"
    when 2
      inner_count = 3
      if p[:elem] == :int
        <<~BODY.chomp
              FOR i IN (1_i64 ..= #{p[:outer]}_i64) DO
                  FOR j IN (1_i64 ..= #{inner_count}_i64) DO
                      #{p[:body] == :frame_alloc ? "MUTABLE scratch: Int64[]@list = List[];\n                    scratch.append(i + j);\n                    lst.append(scratch[0]);" : "lst.append(i + j);"}
                  END
              END
        BODY
      else
        <<~BODY.chomp
              FOR i IN (1_i64 ..= #{p[:outer]}_i64) DO
                  FOR j IN (1_i64 ..= #{inner_count}_i64) DO
                      #{p[:body] == :frame_alloc ? "MUTABLE scratch: String[]@list = List[];\n                    scratch.append(j.toString());\n                    lst.append(COPY scratch[0]);" : "lst.append(j.toString());"}
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
