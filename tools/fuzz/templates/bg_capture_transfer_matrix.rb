# Template: BG capture transfer matrix.
#
# Source-level coverage for move-root collection and ownership-transfer marks
# around BG / DO / BG STREAM boundaries.

BG_CAPTURE_TRANSFER_CELLS = []

%i[bg do bg_stream].each do |boundary|
  %i[string struct_owned list_owned].each do |shape|
    %i[borrow copy give nested_field field_copy list_index_copy call_arg returned_handle].each do |mode|
      expected = :pass
      expected = :compile_error if mode == :field_copy && shape != :struct_owned
      expected = :compile_error if mode == :list_index_copy && shape != :list_owned
      expected = :compile_error if mode == :give && boundary == :do
      expected = :compile_error if boundary == :bg && shape == :struct_owned &&
                                   %i[borrow nested_field returned_handle].include?(mode)
      expected = :compile_error if boundary == :bg && shape == :list_owned && mode == :list_index_copy
      BG_CAPTURE_TRANSFER_CELLS << { boundary: boundary, shape: shape, mode: mode, expected: expected }
    end
  end
end

def bct_type(shape)
  case shape
  when :string then "String"
  when :struct_owned then "Box"
  when :list_owned then "Int64[]@list"
  end
end

def bct_prelude(shape)
  shape == :struct_owned ? "STRUCT Box { label: String }\n" : ""
end

def bct_decl(shape)
  case shape
  when :string
    'v: String = COPY "abc";'
  when :struct_owned
    'v: Box = Box{ label: COPY "abc" };'
  when :list_owned
    "MUTABLE v: Int64[]@list = [];\n    v.append(1_i64);\n    v.append(2_i64);\n    v.append(3_i64);"
  end
end

def bct_observe(shape, expr)
  case shape
  when :string then "#{expr}.length()"
  when :struct_owned then "#{expr}.label.length()"
  when :list_owned then "#{expr}.length()"
  end
end

def bct_use(shape, mode)
  arg = mode == :copy ? "COPY v" : (mode == :give ? "GIVE v" : "v")
  case mode
  when :give
    "consume(#{arg})"
  when :copy
    "observe(#{arg})"
  when :nested_field
    shape == :struct_owned ? "v.label.length()" : bct_observe(shape, "v")
  when :field_copy
    "observeString(COPY v.label)"
  when :list_index_copy
    "v.length() + v[0_i64] - 1_i64"
  when :call_arg
    "observe(#{arg})"
  else
    bct_observe(shape, arg)
  end
end

FuzzGenerator.register(:bg_capture_transfer_matrix, cells: BG_CAPTURE_TRANSFER_CELLS) do |p|
  ty = bct_type(p[:shape])
  prelude = bct_prelude(p[:shape])
  helper = "FN observe(x: #{ty}) RETURNS Int64 -> RETURN #{bct_observe(p[:shape], "x")}; END\n" \
           "FN consume(TAKES x: #{ty}) RETURNS Int64 -> RETURN #{bct_observe(p[:shape], "x")}; END\n" \
           "FN observeString(x: String) RETURNS Int64 -> RETURN x.length(); END\n"
  body_expr = bct_use(p[:shape], p[:mode])

  case p[:boundary]
  when :bg
    if p[:mode] == :returned_handle
      <<~CHT
        #{prelude}#{helper}
        FN make() RETURNS ~Int64 ->
            #{bct_decl(p[:shape])}
            h: ~Int64 = BG { #{bct_observe(p[:shape], "v")}; };
            RETURN GIVE h;
        END
        FN main() RETURNS Void ->
            h: ~Int64 = make();
            ASSERT (NEXT h) == 3_i64, "bg returned handle";
            RETURN;
        END
      CHT
    else
      <<~CHT
        #{prelude}#{helper}
        FN main() RETURNS Void ->
            #{bct_decl(p[:shape])}
            h: ~Int64 = BG { #{body_expr}; };
            ASSERT (NEXT h) == 3_i64, "bg capture transfer";
            RETURN;
        END
      CHT
    end
  when :do
    <<~CHT
      #{prelude}#{helper}
      FN main() RETURNS Void ->
          #{bct_decl(p[:shape])}
          MUTABLE out: Int64[]@list = [];
          DO {
              out.append(#{body_expr}),
              out.append(#{body_expr})
          }
          ASSERT out.length() >= 0_i64, "do capture transfer";
          RETURN;
      END
    CHT
  when :bg_stream
    <<~CHT
      #{prelude}#{helper}
      FN main() RETURNS Void ->
          #{bct_decl(p[:shape])}
          s: ~Int64[] = BG STREAM {
              YIELD #{body_expr};
          };
          ASSERT (NEXT s) == 3_i64, "bg stream capture transfer";
          RETURN;
      END
    CHT
  end
end
