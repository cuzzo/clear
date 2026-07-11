# Template: owned sink destination matrix.
#
# Crosses ownership-bearing source expressions with every sink that should
# consume/materialize them uniformly.

OWNED_SINK_DESTINATION_CELLS = []
OSD_OWNED_VALUE_SHAPES = %i[string list_owned string_list_owned struct_owned union_owned nested_owned].freeze

%i[local move copy call_result or_result branch_result].each do |source|
  %i[return_value struct_field list_append map_put takes_arg normal_arg].each do |sink|
    OSD_OWNED_VALUE_SHAPES.each do |shape|
      expected = :pass
      expected = :compile_error if sink == :normal_arg && source == :move
      expected = :compile_error if sink == :list_append && %i[list_owned string_list_owned].include?(shape)
      OWNED_SINK_DESTINATION_CELLS << { source: source, sink: sink, shape: shape, expected: expected }
    end
  end
end

%i[field_borrow index_borrow].each do |source|
  %i[return_value struct_field takes_arg normal_arg].each do |sink|
    %i[string struct_owned union_owned].each do |shape|
      expected = %i[field_borrow index_borrow].include?(source) && sink == :takes_arg ? :compile_error : :pass
      expected = :compile_error if source == :index_borrow && sink == :struct_field
      expected = :compile_error if source == :index_borrow && sink == :return_value
      expected = :compile_error if shape == :union_owned && sink == :return_value
      OWNED_SINK_DESTINATION_CELLS << { source: source, sink: sink, shape: shape, expected: expected }
    end
  end
end

def osd_prelude(shape)
  case shape
  when :struct_owned
    "STRUCT Box { label: String }\n"
  when :union_owned
    "UNION Val { Empty, Text: String, Items: String[]@list }\n"
  when :nested_owned
    "STRUCT Nest { items: String[]@list }\n"
  else
    ""
  end
end

def osd_type(shape)
  case shape
  when :string then "String"
  when :struct_owned then "Box"
  when :list_owned then "Int64[]@list"
  when :string_list_owned then "String[]@list"
  when :union_owned then "Val"
  when :nested_owned then "Nest"
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
  when :string_list_owned
    "MUTABLE #{name}: String[]@list = List[];\n    #{name}.append(COPY \"a\");\n    #{name}.append(COPY \"b\");\n    #{name}.append(COPY \"c\");"
  when :union_owned
    "#{name}: Val = Val{ Items: mkStringList() };"
  when :nested_owned
    "#{name}: Nest = Nest{ items: mkStringList() };"
  end
end

def osd_return_expr(shape)
  case shape
  when :string then 'COPY "abc"'
  when :struct_owned then 'Box{ label: COPY "abc" }'
  when :list_owned then "mkList()"
  when :string_list_owned then "mkStringList()"
  when :union_owned then "Val{ Items: mkStringList() }"
  when :nested_owned then "Nest{ items: mkStringList() }"
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
           when :string_list_owned then "MUTABLE v: String[]@list = List[];\n    v.append(COPY \"seed\");"
           when :union_owned then "MUTABLE v: Val = Val{ Text: COPY \"seed\" };"
           when :nested_owned then "MUTABLE v: Nest = Nest{ items: mkStringList() };"
           end
    assign = case shape
             when :string then 'v = COPY "abc";'
             when :struct_owned then 'v = Box{ label: COPY "abc" };'
             when :list_owned then "v = mkList();"
             when :string_list_owned then "v = mkStringList();"
             when :union_owned then "v = Val{ Items: mkStringList() };"
             when :nested_owned then "v = Nest{ items: mkStringList() };"
             end
    ["#{init}\n    IF TRUE THEN #{assign} END", "v"]
  when :field_borrow
    ["src: SrcHolder = SrcHolder{ value: #{osd_return_expr(shape)} };", "src.value"]
  when :index_borrow
    ["MUTABLE srcs: #{osd_type(shape)}[]@list = [];\n    srcs.append(#{osd_return_expr(shape)});", "srcs[0_i64]"]
  end
end

def osd_len(shape, name)
  case shape
  when :string then "#{name}.length()"
  when :struct_owned then "#{name}.label.length()"
  when :list_owned, :string_list_owned then "#{name}.length()"
  when :union_owned then "observeVal(#{name})"
  when :nested_owned then "#{name}.items.length()"
  end
end

FuzzGenerator.register(:owned_sink_destination_matrix, cells: OWNED_SINK_DESTINATION_CELLS) do |p|
  ty = osd_type(p[:shape])
  prelude = osd_prelude(p[:shape])
  setup, expr = osd_source_setup(p[:source], p[:shape])
  list_helper = %i[list_owned string_list_owned union_owned nested_owned].include?(p[:shape]) ? <<~CHT : ""
    FN mkList() RETURNS Int64[]@list ->
        MUTABLE xs: Int64[]@list = [];
        xs.append(1_i64);
        xs.append(2_i64);
        xs.append(3_i64);
        RETURN xs;
    END

    FN mkStringList() RETURNS String[]@list ->
        MUTABLE xs: String[]@list = List[];
        xs.append(COPY "a");
        xs.append(COPY "b");
        xs.append(COPY "c");
        RETURN xs;
    END
  CHT
  union_helper = p[:shape] == :union_owned ? <<~CHT : ""
    FN observeVal(x: Val) RETURNS Int64 ->
        PARTIAL MATCH x START
            Val.Text AS s -> RETURN s.length();,
            Val.Items AS items -> RETURN items.length();,
            DEFAULT -> RETURN 0_i64;
        END
    END
  CHT
  helpers = <<~CHT
    #{prelude}#{list_helper}#{union_helper}
    STRUCT SrcHolder { value: #{ty} }

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
    if p[:source] == :index_borrow
      # A union payload owns its active variant. Materialize the indexed borrow
      # explicitly before crossing a by-value argument boundary.
      observe_borrowed = if p[:shape] == :union_owned
        "owned: #{ty} = COPY borrowed;\n            ASSERT observe(owned) == 3_i64, \"owned sink arg\";"
      else
        "ASSERT observe(borrowed) == 3_i64, \"owned sink arg\";"
      end
      <<~CHT
        #{helpers}
        FN main() RETURNS Void ->
            #{setup}
            IF #{expr} AS borrowed THEN
                #{observe_borrowed}
            ELSE
                ASSERT FALSE, "indexed source should exist";
            END
            RETURN;
        END
      CHT
    else
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
end
