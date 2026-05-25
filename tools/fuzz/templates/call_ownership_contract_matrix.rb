# Template: call ownership contracts.
#
# Normal functions, fallible functions, stdlib method calls, TAKES params,
# receiver mutation, and returned owned aggregates all flow through the same
# call-contract facts. This template intentionally avoids stdlib-specific
# expectations: stdlib calls are just calls with signatures/effects.

CALL_OWNERSHIP_CELLS = []

[:string, :list, :struct_string, :nested_list].each do |shape|
  [:borrow_arg, :copy_arg, :give_takes, :return_owned, :return_or_fallback,
   :receiver_mutation, :bg_call, :pipeline_call].each do |mode|
    next if mode == :receiver_mutation && shape == :string
    next if mode == :pipeline_call && shape != :string
    cell = { shape: shape, mode: mode }
    cell[:expected] = :compile_error if mode == :pipeline_call
    CALL_OWNERSHIP_CELLS << cell
  end
end

def com_type(shape)
  case shape
  when :string then "String"
  when :list then "Int64[]@list"
  when :struct_string then "Box"
  when :nested_list then "Nest"
  end
end

def com_prelude(shape)
  case shape
  when :struct_string
    "STRUCT Box { name: String }\n"
  when :nested_list
    "STRUCT Nest { items: Int64[]@list }\n"
  else
    ""
  end
end

def com_decl(shape, name = "v")
  case shape
  when :string then "#{name}: String = COPY \"abc\";"
  when :list then "MUTABLE #{name}: Int64[]@list = []; #{name}.append(1_i64);"
  when :struct_string then "#{name}: Box = Box{ name: COPY \"abc\" };"
  when :nested_list then "MUTABLE inner: Int64[]@list = []; inner.append(1_i64); #{name}: Nest = Nest{ items: inner };"
  end
end

def com_len_expr(shape, name = "x")
  case shape
  when :string then "#{name}.length()"
  when :list then "#{name}.length()"
  when :struct_string then "#{name}.name.length()"
  when :nested_list then "#{name}.items.length()"
  end
end

def com_literal(shape)
  case shape
  when :string then 'COPY "abc"'
  when :list then "mkList() OR RAISE"
  when :struct_string then 'Box{ name: COPY "abc" }'
  when :nested_list then "Nest{ items: mkList() OR RAISE }"
  end
end

FuzzGenerator.register(:call_ownership_contract_matrix, cells: CALL_OWNERSHIP_CELLS) do |p|
  ty = com_type(p[:shape])
  pre = com_prelude(p[:shape])
  helper_list = <<~CHT
    FN mkList() RETURNS !Int64[]@list ->
      MUTABLE xs: Int64[]@list = [];
      xs.append(1_i64);
      RETURN xs;
    END
  CHT

  case p[:mode]
  when :borrow_arg, :copy_arg
    arg = p[:mode] == :copy_arg ? "COPY v" : "v"
    <<~CHT
      #{pre}#{helper_list}
      FN observe(x: #{ty}) RETURNS Int64 -> RETURN #{com_len_expr(p[:shape])}; END

      FN main() RETURNS !Void ->
        #{com_decl(p[:shape])}
        ASSERT observe(#{arg}) == #{p[:shape] == :string || p[:shape] == :struct_string ? 3 : 1}_i64, "call ownership arg";
        RETURN;
      END
    CHT

  when :give_takes
    <<~CHT
      #{pre}#{helper_list}
      FN consume(TAKES x: #{ty}) RETURNS Int64 -> RETURN #{com_len_expr(p[:shape])}; END

      FN main() RETURNS !Void ->
        #{com_decl(p[:shape])}
        ASSERT consume(GIVE v) == #{p[:shape] == :string || p[:shape] == :struct_string ? 3 : 1}_i64, "call TAKES give";
        RETURN;
      END
    CHT

  when :return_owned
    <<~CHT
      #{pre}#{helper_list}
      FN make() RETURNS !#{ty} ->
        RETURN #{com_literal(p[:shape])};
      END

      FN main() RETURNS !Void ->
        v: #{ty} = make() OR RAISE;
        ASSERT #{com_len_expr(p[:shape], "v")} == #{p[:shape] == :string || p[:shape] == :struct_string ? 3 : 1}_i64, "call return owned";
        RETURN;
      END
    CHT

  when :return_or_fallback
    fallback = case p[:shape]
               when :string then 'COPY "fallback"'
               when :list then "mkList() OR RAISE"
               when :struct_string then 'Box{ name: COPY "fallback" }'
               when :nested_list then "Nest{ items: mkList() OR RAISE }"
               end
    <<~CHT
      #{pre}#{helper_list}
      FN maybe(flag: Bool) RETURNS !#{ty} ->
        IF flag THEN RETURN #{com_literal(p[:shape])}; END
        RAISE "no";
      END

      FN main() RETURNS !Void ->
        v: #{ty} = maybe(FALSE) OR #{fallback};
        ASSERT #{com_len_expr(p[:shape], "v")} >= 1_i64, "call return fallback";
        RETURN;
      END
    CHT

  when :receiver_mutation
    append = case p[:shape]
             when :list then "v.append(2_i64);"
             when :struct_string then 'v.name = v.name + COPY "d";'
             when :nested_list then "v.items.append(2_i64);"
             end
    assert_expr = case p[:shape]
                  when :list then "v.length()"
                  when :struct_string then "v.name.length()"
                  when :nested_list then "v.items.length()"
                  end
    decl = com_decl(p[:shape])
    decl = decl.sub(/\Av:/, "MUTABLE v:")
    decl = decl.sub(/ v: Nest/, " MUTABLE v: Nest")
    <<~CHT
      #{pre}#{helper_list}
      FN main() RETURNS !Void ->
        #{decl}
        #{append}
        ASSERT #{assert_expr} >= 2_i64, "call receiver mutation";
        RETURN;
      END
    CHT

  when :bg_call
    <<~CHT
      #{pre}#{helper_list}
      FN observe(x: #{ty}) RETURNS Int64 -> RETURN #{com_len_expr(p[:shape])}; END

      FN main() RETURNS !Void ->
        #{com_decl(p[:shape])}
        f: ~Int64 = BG { observe(COPY v); };
        ASSERT (NEXT f) >= 1_i64, "call from bg";
        RETURN;
      END
    CHT

  when :pipeline_call
    <<~CHT
      FN size(s: String) RETURNS Int64 -> RETURN s.length(); END

      FN main() RETURNS Void ->
        src: ~?String[] = BG STREAM {
          a: String = COPY "a";
          b: String = COPY "bb";
          c: String = COPY "ccc";
          YIELD a;
          YIELD b;
          YIELD c;
        };
        running: ~Int64@observable = src |> SELECT size(_) |> SUM _;
        total = NEXT running;
        ASSERT total == 6_i64, "call in pipeline";
        RETURN;
      END
    CHT
  end
end
