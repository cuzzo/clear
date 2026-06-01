# Template: Auto inference and rejection paths.
#
# Source-level cells for explicit `Auto` placeholders. Positive cases exercise
# concrete constraints collected from calls, returns, locals, and empty
# collection literals; negative cases exercise ambiguity and parser/admission
# rejection paths.

AUTO_INFERENCE_CELLS = [
  { shape: :param_int },
  # These compile through Ruby inference today but emit invalid Zig or invalid
  # string lowering. Keep them as negative fuzz sentinels until Auto reification
  # reaches the emitter.
  { shape: :param_string, expected: :compile_error },
  { shape: :return_int },
  { shape: :local_scalar, expected: :compile_error },
  { shape: :local_string, expected: :compile_error },
  { shape: :local_empty_list, expected: :compile_error },
  { shape: :local_empty_map, expected: :compile_error },
  { shape: :mutable_reassign, expected: :compile_error },
  { shape: :ambiguous_param, expected: :compile_error },
  { shape: :unresolved_param, expected: :compile_error },
  { shape: :unresolved_return, expected: :compile_error },
  { shape: :inconsistent_local_reassign, expected: :compile_error },
  { shape: :struct_field_auto, expected: :compile_error },
  { shape: :optional_auto, expected: :compile_error },
  { shape: :fallible_auto, expected: :compile_error },
].freeze

FuzzGenerator.register(:auto_inference_matrix, cells: AUTO_INFERENCE_CELLS) do |p|
  case p[:shape]
  when :param_int
    <<~CHT
      FN double(x: Auto) RETURNS Int64 ->
        RETURN x + x;
      END

      FN main() RETURNS Void ->
        ASSERT double(5_i64) == 10_i64, "auto param int";
        RETURN;
      END
    CHT

  when :param_string
    <<~CHT
      FN join(x: Auto) RETURNS String ->
        RETURN x + x;
      END

      FN main() RETURNS Void ->
        out: String = join("ab");
        ASSERT out.length() == 4_i64, "auto param string";
        RETURN;
      END
    CHT

  when :return_int
    <<~CHT
      FN build(x: Int64) RETURNS Auto ->
        RETURN x + 1_i64;
      END

      FN main() RETURNS Void ->
        y: Int64 = build(4_i64);
        ASSERT y == 5_i64, "auto return int";
        RETURN;
      END
    CHT

  when :local_scalar
    <<~CHT
      FN main() RETURNS Void ->
        x: Auto = 42_i64;
        ASSERT x + 1_i64 == 43_i64, "auto local scalar";
        RETURN;
      END
    CHT

  when :local_string
    <<~CHT
      FN main() RETURNS Void ->
        s: Auto = COPY "auto";
        t: String = s;
        ASSERT t.length() == 4_i64, "auto local string";
        RETURN;
      END
    CHT

  when :local_empty_list
    <<~CHT
      FN main() RETURNS Void ->
        MUTABLE xs: Auto = [];
        xs.append(1_i64);
        xs.append(2_i64);
        ASSERT xs.length() == 2_i64, "auto list shape";
        RETURN;
      END
    CHT

  when :local_empty_map
    <<~CHT
      FN main() RETURNS Void ->
        MUTABLE h: Auto = {};
        h["a"] = 7_i64;
        ASSERT h["a"] == 7_i64, "auto map shape";
        RETURN;
      END
    CHT

  when :mutable_reassign
    <<~CHT
      FN main() RETURNS Void ->
        MUTABLE x: Auto = 1_i64;
        x = x + 1_i64;
        ASSERT x == 2_i64, "auto mutable reassign";
        RETURN;
      END
    CHT

  when :ambiguous_param
    <<~CHT
      FN echo(x: Auto) RETURNS Int64 ->
        y = x + x;
        RETURN 0_i64;
      END

      FN main() RETURNS Void ->
        a = echo(5_i64);
        b = echo("hello");
        RETURN;
      END
    CHT

  when :unresolved_param
    <<~CHT
      FN divide(x: Auto) RETURNS Int64 ->
        y = x / 2_i64;
        RETURN y;
      END

      FN main() RETURNS Void ->
        RETURN;
      END
    CHT

  when :unresolved_return
    <<~CHT
      FN id(x: Auto) RETURNS Auto ->
        RETURN x;
      END

      FN main() RETURNS Void ->
        RETURN;
      END
    CHT

  when :inconsistent_local_reassign
    <<~CHT
      FN main() RETURNS Void ->
        MUTABLE x: Auto = 1_i64;
        x = COPY "nope";
        RETURN;
      END
    CHT

  when :struct_field_auto
    <<~CHT
      STRUCT Box { value: Auto }
      FN main() RETURNS Void -> RETURN; END
    CHT

  when :optional_auto
    <<~CHT
      FN main() RETURNS Void ->
        x: ?Auto = nil;
        RETURN;
      END
    CHT

  when :fallible_auto
    <<~CHT
      FN main() RETURNS !Void ->
        x: !Auto = 1_i64;
        RETURN;
      END
    CHT
  end
end
