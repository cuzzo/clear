# Template: recursive THUNK lowering matrix.
#
# Drives the thunk splitter/emitter through direct recurrence, tail
# recurrence, mutual cycles, return-type variation, and argument-shape
# variation. These are valid recursive programs; a MIR/codegen/runtime failure
# is a compiler bug, not a generator limitation.

THUNK_RECURSION_CELLS = []

[:sum, :factorial, :tail_acc, :struct_param, :generic_like].each do |shape|
  [0, 1, 8, 64].each { |depth| THUNK_RECURSION_CELLS << { family: :direct, shape: shape, depth: depth } }
end

[:two_cycle_bool, :three_cycle_int].each do |shape|
  [0, 1, 9, 60].each { |depth| THUNK_RECURSION_CELLS << { family: :mutual, shape: shape, depth: depth } }
end

[:float_sum, :not_logical].each do |shape|
  [0, 1, 10].each do |depth|
    cell = { family: :scalar_variant, shape: shape, depth: depth }
    cell[:expected] = :compile_error if shape == :not_logical
    THUNK_RECURSION_CELLS << cell
  end
end

[:owned_string_acc, :struct_return, :mutual_struct_arg].each do |shape|
  [0, 1, 6].each do |depth|
    THUNK_RECURSION_CELLS << { family: :owned_variant, shape: shape, depth: depth }
  end
end

FuzzGenerator.register(:thunk_recursion_matrix, cells: THUNK_RECURSION_CELLS) do |p|
  n = p[:depth]

  case p[:shape]
  when :sum
    expected = n * (n + 1) / 2
    <<~CHT
      FN sum_down(n: Int64) RETURNS Int64
        EFFECTS REENTRANT:THUNK ->
        IF n <= 0_i64 -> RETURN 0_i64;
        RETURN n + sum_down(n - 1_i64);
      END

      FN main() RETURNS Void ->
        ASSERT sum_down(#{n}_i64) == #{expected}_i64, "direct thunk sum";
        RETURN;
      END
    CHT

  when :factorial
    capped = [n, 10].min
    expected = (1..[capped, 1].max).reduce(1) { |a, b| a * b }
    <<~CHT
      FN factorial(n: Int64) RETURNS Int64
        EFFECTS REENTRANT:THUNK ->
        IF n <= 1_i64 -> RETURN 1_i64;
        RETURN n * factorial(n - 1_i64);
      END

      FN main() RETURNS Void ->
        ASSERT factorial(#{capped}_i64) == #{expected}_i64, "direct thunk factorial";
        RETURN;
      END
    CHT

  when :tail_acc
    expected = n * (n + 1) / 2
    <<~CHT
      FN sum_tail(n: Int64, acc: Int64) RETURNS Int64
        EFFECTS REENTRANT:THUNK ->
        IF n <= 0_i64 -> RETURN acc;
        RETURN sum_tail(n - 1_i64, acc + n);
      END

      FN main() RETURNS Void ->
        ASSERT sum_tail(#{n}_i64, 0_i64) == #{expected}_i64, "tail thunk accumulator";
        RETURN;
      END
    CHT

  when :struct_param
    expected = n * 2
    <<~CHT
      STRUCT Box { inc: Int64 }

      FN walk(b: Box, n: Int64) RETURNS Int64
        EFFECTS REENTRANT:THUNK ->
        IF n <= 0_i64 -> RETURN 0_i64;
        RETURN b.inc + walk(b, n - 1_i64);
      END

      FN main() RETURNS Void ->
        b = Box{ inc: 2_i64 };
        ASSERT walk(b, #{n}_i64) == #{expected}_i64, "thunk struct param";
        RETURN;
      END
    CHT

  when :generic_like
    expected = n * (n + 1) / 2
    <<~CHT
      FN one() RETURNS Int64 -> RETURN 1_i64; END

      FN count_with_stride(n: Int64, stride: Int64) RETURNS Int64
        EFFECTS REENTRANT:THUNK ->
        IF n <= 0_i64 -> RETURN 0_i64;
        RETURN n + count_with_stride(n - stride, stride);
      END

      FN main() RETURNS Void ->
        ASSERT count_with_stride(#{n}_i64, one()) == #{expected}_i64, "thunk call arg";
        RETURN;
      END
    CHT

  when :two_cycle_bool
    even = n.even? ? "TRUE" : "FALSE"
    <<~CHT
      FN is_even(n: Int64) RETURNS Bool
        EFFECTS REENTRANT:THUNK ->
        IF n == 0_i64 -> RETURN TRUE;
        RETURN is_odd(n - 1_i64);
      END

      FN is_odd(n: Int64) RETURNS Bool
        EFFECTS REENTRANT:THUNK ->
        IF n == 0_i64 -> RETURN FALSE;
        RETURN is_even(n - 1_i64);
      END

      FN main() RETURNS Void ->
        ASSERT is_even(#{n}_i64) == #{even}, "mutual thunk even";
        RETURN;
      END
    CHT

  when :three_cycle_int
    expected = (n % 3) + 1
    <<~CHT
      FN cycleA(n: Int64) RETURNS Int64
        EFFECTS REENTRANT:THUNK ->
        IF n == 0_i64 -> RETURN 1_i64;
        RETURN cycleB(n - 1_i64);
      END

      FN cycleB(n: Int64) RETURNS Int64
        EFFECTS REENTRANT:THUNK ->
        IF n == 0_i64 -> RETURN 2_i64;
        RETURN cycleC(n - 1_i64);
      END

      FN cycleC(n: Int64) RETURNS Int64
        EFFECTS REENTRANT:THUNK ->
        IF n == 0_i64 -> RETURN 3_i64;
        RETURN cycleA(n - 1_i64);
      END

      FN main() RETURNS Void ->
        ASSERT cycleA(#{n}_i64) == #{expected}_i64, "mutual thunk three-cycle";
        RETURN;
      END
    CHT

  when :float_sum
    expected = n * (n + 1) / 2
    <<~CHT
      FN sumF(n: Float64) RETURNS Float64
        EFFECTS REENTRANT:THUNK ->
        IF n <= 0.0 -> RETURN 0.0;
        RETURN n + sumF(n - 1.0);
      END

      FN main() RETURNS Void ->
        ASSERT sumF(#{n}.0) == #{expected}.0, "float thunk sum";
        RETURN;
      END
    CHT

  when :not_logical
    expected = n.even? ? "TRUE" : "FALSE"
    <<~CHT
      FN flip(n: Int64) RETURNS Bool
        EFFECTS REENTRANT:THUNK ->
        IF n == 0_i64 -> RETURN TRUE;
        RETURN !flip(n - 1_i64);
      END

      FN main() RETURNS Void ->
        ASSERT flip(#{n}_i64) == #{expected}, "logical thunk";
        RETURN;
      END
    CHT
  when :owned_string_acc
    expected = n
    <<~CHT
      FN repeat(n: Int64, acc: String) RETURNS String
        EFFECTS REENTRANT:THUNK ->
        IF n <= 0_i64 -> RETURN acc;
        RETURN repeat(n - 1_i64, acc + COPY "x");
      END

      FN main() RETURNS Void ->
        s: String = repeat(#{n}_i64, COPY "");
        ASSERT s.length() == #{expected}_i64, "thunk owned string acc";
        RETURN;
      END
    CHT

  when :struct_return
    expected = n
    <<~CHT
      STRUCT Box { label: String, count: Int64 }

      FN build(n: Int64, b: Box) RETURNS Box
        EFFECTS REENTRANT:THUNK ->
        IF n <= 0_i64 -> RETURN b;
        RETURN build(n - 1_i64, Box{ label: COPY b.label, count: b.count + 1_i64 });
      END

      FN main() RETURNS Void ->
        seed = Box{ label: COPY "abc", count: 0_i64 };
        b: Box = build(#{n}_i64, seed);
        ASSERT b.count == #{expected}_i64, "thunk struct return count";
        ASSERT b.label.length() == 3_i64, "thunk struct return label";
        RETURN;
      END
    CHT

  when :mutual_struct_arg
    expected = n
    <<~CHT
      STRUCT Box { step: Int64 }

      FN a(n: Int64, b: Box) RETURNS Int64
        EFFECTS REENTRANT:THUNK ->
        IF n <= 0_i64 -> RETURN b.step;
        RETURN bfn(n - 1_i64, b);
      END

      FN bfn(n: Int64, b: Box) RETURNS Int64
        EFFECTS REENTRANT:THUNK ->
        IF n <= 0_i64 -> RETURN b.step;
        RETURN a(n - 1_i64, b);
      END

      FN main() RETURNS Void ->
        b = Box{ step: 1_i64 };
        ASSERT a(#{n}_i64, b) == 1_i64, "thunk mutual struct arg";
        RETURN;
      END
    CHT
  end
end
