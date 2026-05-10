# Template: a loop-LOCAL collection escapes into an outer collection.
# Stresses the loop-frame promotion path (commit 9fa21926: "cover escaping
# frame collections in loops"). Pre-fix, only loop-local Strings were
# promoted to heap on escape; lists/maps/arrays leaked or UAF'd.
#
# Pattern:
#   MUTABLE outer: Int64[][]@list = [];
#   FOR ... DO
#       MUTABLE inner: Int64[]@list = [];   # loop-local, frame
#       inner.append(...);
#       outer.append(inner);                # escape -> must heap-promote
#   END

NESTED_LOOP_ESCAPE_CELLS = []

[:list, :array].each do |inner_kind|
  [:while, :for].each do |loop_kind|
    [1, 3].each do |outer_iters|
      NESTED_LOOP_ESCAPE_CELLS << { inner_kind: inner_kind, loop_kind: loop_kind, iters: outer_iters }
    end
  end
end

FuzzGenerator.register(:nested_loop_escape, cells: NESTED_LOOP_ESCAPE_CELLS) do |p|
  outer_decl = "MUTABLE outer: Int64[][]@list = [];"

  inner_block = case p[:inner_kind]
  when :list
    <<~BODY.chomp
              MUTABLE inner: Int64[]@list = [];
              inner.append(i);
              inner.append(i + 1_i64);
              outer.append(inner);
    BODY
  when :array
    <<~BODY.chomp
              inner: Int64[] = [i, i + 1_i64];
              outer.append(inner);
    BODY
  end

  loop_block = case p[:loop_kind]
  when :while
    <<~LOOP.chomp
          MUTABLE i: Int64 = 0_i64;
          WHILE i < #{p[:iters]}_i64 DO
      #{inner_block}
              i = i + 1_i64;
          END
    LOOP
  when :for
    <<~LOOP.chomp
          FOR i IN (0_i64 ..< #{p[:iters]}_i64) DO
      #{inner_block}
          END
    LOOP
  end

  <<~CHT
    FN main() RETURNS Void ->
        #{outer_decl}
    #{loop_block}
        ASSERT length(outer) == #{p[:iters]}_i64, "outer list length";
        ASSERT length(outer[0_i64]) == 2_i64, "first inner length";
        ASSERT outer[0_i64][0_i64] == 0_i64, "first inner first element";
        RETURN;
    END
  CHT
end
