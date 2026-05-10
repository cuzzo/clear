# Template: collection built inside a loop and used after the loop.
# Stresses E2 :loop_carry_string and the loop-escape promotion path
# (recent commits 9fa21926, d80e6539, 1599bfb1).
#
# Pattern: declare a list, push to it inside FOR, then read length/contents
# after the loop. Loop-local mark/rewind must NOT free the list's backing
# buffer (it lives in the enclosing frame, not the loop's per-iter frame).

LOOP_CARRY_CELLS = []

[:int, :string].each do |elem|
  [1, 2].each do |depth|
    [5, 12].each do |outer|
      LOOP_CARRY_CELLS << { elem: elem, depth: depth, outer: outer }
    end
  end
end

FuzzGenerator.register(:loop_carry_collection, cells: LOOP_CARRY_CELLS) do |p|
  zig_type = (p[:elem] == :int) ? "Int64" : "String"
  type_decl = "#{zig_type}[]@list"

  push_expr = (p[:elem] == :int) ? "i" : "i.toString()"

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
