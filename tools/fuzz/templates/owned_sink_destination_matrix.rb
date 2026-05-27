# Template: owned sink destination matrix.
#
# Crosses ownership-bearing source expressions with every sink that should
# consume/materialize them uniformly.

OWNED_SINK_DESTINATION_CELLS = []

%i[local move copy call_result or_result branch_result].each do |source|
  %i[return_value struct_field list_append map_put takes_arg normal_arg].each do |sink|
    %i[string struct_owned list_owned].each do |shape|
      expected = :pass
      expected = :compile_error if sink == :normal_arg && source == :move
      expected = :compile_error if sink == :list_append && shape == :list_owned
      OWNED_SINK_DESTINATION_CELLS << { source: source, sink: sink, shape: shape, expected: expected }
    end
  end
end

def osd_prelude(shape)
  shape == :struct_owned ? "STRUCT Box { label: String }\n" : ""
end

def osd_type(shape)
  case shape
  when :string then "String"
  when :struct_owned then "Box"
  when :list_owned then "Int64[]@list"
  end
end

def osd_build_value(shape, name = "v")
  case shape
  when :string
    "#{name}: String = COPY \"abc\";"
  when :struct_owned
    "#{name}: Box = Box{ label: COPY \"abc\" };"
  when :list_owned
    "MUTABLE #{name}: Int64[]@list = [];\n    #{name}.append(1_i64);\n    #{name}.append(2_i64);\n    #{name}.append(3_i64);"
  end
end

def osd_return_expr(shape)
  case shape
  when :string then 'COPY "abc"'
  when :struct_owned then 'Box{ label: COPY "abc" }'
  when :list_owned then "mkList()"
  end
end

def osd_source_setup(source, shape)
  case source
  when :local
    [osd_build_value(shape), "v"]
  when :move
    [osd_build_value(shape), "GIVE v"]
  when :copy
    [osd_build_value(shape), "COPY v"]
  when :call_result
    ["", "make() OR #{osd_return_expr(shape)}"]
  when :or_result
    ["", "maybe(FALSE) OR #{osd_return_expr(shape)}"]
  when :branch_result
    init = case shape
           when :string then 'MUTABLE v: String = COPY "seed";'
           when :struct_owned then 'MUTABLE v: Box = Box{ label: COPY "seed" };'
           when :list_owned then "MUTABLE v: Int64[]@list = [];\n    v.append(0_i64);"
           end
    assign = case shape
             when :string then 'v = COPY "abc";'
             when :struct_owned then 'v = Box{ label: COPY "abc" };'
             when :list_owned then "v = mkList();"
             end
    ["#{init}\n    IF TRUE THEN #{assign} END", "v"]
  end
end

def osd_len(shape, name)
  case shape
  when :string then "#{name}.length()"
  when :struct_owned then "#{name}.label.length()"
  when :list_owned then "#{name}.length()"
  end
end

FuzzGenerator.register(:owned_sink_destination_matrix, cells: OWNED_SINK_DESTINATION_CELLS) do |p|
  ty = osd_type(p[:shape])
  prelude = osd_prelude(p[:shape])
  setup, expr = osd_source_setup(p[:source], p[:shape])
  list_helper = p[:shape] == :list_owned ? <<~CHT : ""
    FN mkList() RETURNS Int64[]@list ->
        MUTABLE xs: Int64[]@list = [];
        xs.append(1_i64);
        xs.append(2_i64);
        xs.append(3_i64);
        RETURN xs;
    END
  CHT
  helpers = <<~CHT
    #{prelude}#{list_helper}
    FN make() RETURNS !#{ty} ->
        RETURN #{osd_return_expr(p[:shape])};
    END

    FN maybe(flag: Bool) RETURNS !#{ty} ->
        IF flag THEN RETURN #{osd_return_expr(p[:shape])}; END
        RAISE "no";
    END

    FN consume(TAKES x: #{ty}) RETURNS Int64 ->
        RETURN #{osd_len(p[:shape], "x")};
    END

    FN observe(x: #{ty}) RETURNS Int64 ->
        RETURN #{osd_len(p[:shape], "x")};
    END
  CHT

  case p[:sink]
  when :return_value
    return_type = p[:source] == :or_result ? "!#{ty}" : ty
    call_expr = p[:source] == :or_result ? "build() OR #{osd_return_expr(p[:shape])}" : "build()"
    <<~CHT
      #{helpers}
      FN build() RETURNS #{return_type} ->
          #{setup}
          RETURN #{expr};
      END
      FN main() RETURNS Void ->
          v: #{ty} = #{call_expr};
          ASSERT #{osd_len(p[:shape], "v")} == 3_i64, "owned sink return";
          RETURN;
      END
    CHT
  when :struct_field
    <<~CHT
      #{helpers}
      STRUCT Holder { value: #{ty} }
      FN main() RETURNS Void ->
          #{setup}
          h: Holder = Holder{ value: #{expr} };
          ASSERT #{osd_len(p[:shape], "h.value")} == 3_i64, "owned sink field";
          RETURN;
      END
    CHT
  when :list_append
    <<~CHT
      #{helpers}
      FN main() RETURNS Void ->
          #{setup}
          MUTABLE out: #{ty}[]@list = [];
          out.append(#{expr});
          ASSERT out.length() == 1_i64, "owned sink list";
          RETURN;
      END
    CHT
  when :map_put
    <<~CHT
      #{helpers}
      FN main() RETURNS Void ->
          #{setup}
          MUTABLE out: HashMap<#{ty}> = {};
          out["k"] = #{expr};
          ASSERT out.count() == 1_i64, "owned sink map";
          RETURN;
      END
    CHT
  when :takes_arg
    <<~CHT
      #{helpers}
      FN main() RETURNS Void ->
          #{setup}
          ASSERT consume(#{expr}) == 3_i64, "owned sink TAKES";
          RETURN;
      END
    CHT
  when :normal_arg
    <<~CHT
      #{helpers}
      FN main() RETURNS Void ->
          #{setup}
          ASSERT observe(#{expr}) == 3_i64, "owned sink arg";
          RETURN;
      END
    CHT
  end
end
