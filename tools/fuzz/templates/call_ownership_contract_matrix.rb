# Template: call ownership contracts.
#
# Normal functions, fallible functions, stdlib method calls, TAKES params,
# receiver mutation, and returned owned aggregates all flow through the same
# call-contract facts. This template intentionally avoids stdlib-specific
# expectations: stdlib calls are just calls with signatures/effects.

CALL_OWNERSHIP_CELLS = []
CALL_OWNERSHIP_VALUE_SHAPES = %i[
  string list string_list struct_string union_owned nested_list nested_string_list
].freeze

CALL_OWNERSHIP_VALUE_SHAPES.each do |shape|
  [:borrow_arg, :copy_arg, :bare_takes, :copy_takes, :give_takes,
   :return_owned, :return_or_fallback, :fallible_arg,
   :receiver_mutation, :bg_call, :pipeline_call].each do |mode|
    next if mode == :receiver_mutation && %i[string union_owned].include?(shape)
    next if mode == :pipeline_call && shape != :string
    cell = { shape: shape, mode: mode }
    cell[:expected] = :compile_error if mode == :pipeline_call
    CALL_OWNERSHIP_CELLS << cell
  end
end

%i[
  named_lifetime_return wildcard_lifetime_return
  mutable_lifetime_plain mixed_atomic_return_lifetime
].each do |mode|
  CALL_OWNERSHIP_CELLS << {
    shape: :string,
    mode: mode,
    expected: %i[mutable_lifetime_plain mixed_atomic_return_lifetime].include?(mode) ? :compile_error : :pass
  }
end

def com_type(shape)
  case shape
  when :string then "String"
  when :list then "Int64[]@list"
  when :string_list then "String[]@list"
  when :struct_string then "Box"
  when :union_owned then "Val"
  when :nested_list then "Nest"
  when :nested_string_list then "StringNest"
  end
end

def com_prelude(shape)
  case shape
  when :struct_string
    "STRUCT Box { name: String }\n"
  when :union_owned
    <<~CHT
      UNION Val { Empty, Text: String, Items: String[]@list }
      FN observeVal(x: Val) RETURNS Int64 ->
          PARTIAL MATCH x START
              Val.Text AS s -> RETURN s.length();,
              Val.Items AS items -> RETURN items.length();,
              DEFAULT -> RETURN 0_i64;
          END
      END
    CHT
  when :nested_list
    "STRUCT Nest { items: Int64[]@list }\n"
  when :nested_string_list
    "STRUCT StringNest { items: String[]@list }\n"
  else
    ""
  end
end

def com_decl(shape, name = "v")
  case shape
  when :string then "#{name}: String = COPY \"abc\";"
  when :list then "MUTABLE #{name}: Int64[]@list = []; #{name}.append(1_i64);"
  when :string_list then "#{name}: String[]@list = mkStringList() OR_ELSE RAISE;"
  when :struct_string then "#{name}: Box = Box{ name: COPY \"abc\" };"
  when :union_owned then "#{name}: Val = Val{ Items: mkStringList() OR_ELSE RAISE };"
  when :nested_list then "MUTABLE inner: Int64[]@list = []; inner.append(1_i64); #{name}: Nest = Nest{ items: inner };"
  when :nested_string_list then "#{name}: StringNest = StringNest{ items: mkStringList() OR_ELSE RAISE };"
  end
end

def com_len_expr(shape, name = "x")
  case shape
  when :string then "#{name}.length()"
  when :list then "#{name}.length()"
  when :string_list then "#{name}.length()"
  when :struct_string then "#{name}.name.length()"
  when :union_owned then "observeVal(#{name})"
  when :nested_list then "#{name}.items.length()"
  when :nested_string_list then "#{name}.items.length()"
  end
end

def com_literal(shape)
  case shape
  when :string then 'COPY "abc"'
  when :list then "mkList() OR_ELSE RAISE"
  when :string_list then "mkStringList() OR_ELSE RAISE"
  when :struct_string then 'Box{ name: COPY "abc" }'
  when :union_owned then "Val{ Items: mkStringList() OR_ELSE RAISE }"
  when :nested_list then "Nest{ items: mkList() OR_ELSE RAISE }"
  when :nested_string_list then "StringNest{ items: mkStringList() OR_ELSE RAISE }"
  end
end

def com_expected_count(shape)
  %i[string struct_string].include?(shape) ? 3 : 1
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

    FN mkStringList() RETURNS !String[]@list ->
      MUTABLE xs: String[]@list = List[];
      xs.append(COPY "a");
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
        ASSERT observe(#{arg}) == #{com_expected_count(p[:shape])}_i64, "call ownership arg";
        RETURN;
      END
    CHT

  when :bare_takes, :copy_takes
    arg = p[:mode] == :copy_takes ? "COPY v" : "v"
    <<~CHT
      #{pre}#{helper_list}
      FN consume(TAKES x: #{ty}) RETURNS Int64 -> RETURN #{com_len_expr(p[:shape])}; END

      FN main() RETURNS !Void ->
        #{com_decl(p[:shape])}
        ASSERT consume(#{arg}) == #{com_expected_count(p[:shape])}_i64, "call TAKES modality";
        RETURN;
      END
    CHT

  when :give_takes
    <<~CHT
      #{pre}#{helper_list}
      FN consume(TAKES x: #{ty}) RETURNS Int64 -> RETURN #{com_len_expr(p[:shape])}; END

      FN main() RETURNS !Void ->
        #{com_decl(p[:shape])}
        ASSERT consume(GIVE v) == #{com_expected_count(p[:shape])}_i64, "call TAKES give";
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
        v: #{ty} = make() OR_ELSE RAISE;
        ASSERT #{com_len_expr(p[:shape], "v")} == #{com_expected_count(p[:shape])}_i64, "call return owned";
        RETURN;
      END
    CHT

  when :return_or_fallback
    fallback = case p[:shape]
               when :string then 'COPY "fallback"'
               when :list then "mkList() OR_ELSE RAISE"
               when :string_list then "mkStringList() OR_ELSE RAISE"
               when :struct_string then 'Box{ name: COPY "fallback" }'
               when :union_owned then "Val{ Items: mkStringList() OR_ELSE RAISE }"
               when :nested_list then "Nest{ items: mkList() OR_ELSE RAISE }"
               when :nested_string_list then "StringNest{ items: mkStringList() OR_ELSE RAISE }"
               end
    <<~CHT
      #{pre}#{helper_list}
      FN maybe(flag: Bool) RETURNS !#{ty} ->
        IF flag THEN RETURN #{com_literal(p[:shape])}; END
        RAISE "no";
      END

      FN main() RETURNS !Void ->
        v: #{ty} = maybe(FALSE) OR_ELSE #{fallback};
        ASSERT #{com_len_expr(p[:shape], "v")} >= 1_i64, "call return fallback";
        RETURN;
      END
    CHT

  when :fallible_arg
    fallback = case p[:shape]
               when :string then 'COPY "fallback"'
               when :list then "mkList() OR_ELSE RAISE"
               when :string_list then "mkStringList() OR_ELSE RAISE"
               when :struct_string then 'Box{ name: COPY "fallback" }'
               when :union_owned then "Val{ Items: mkStringList() OR_ELSE RAISE }"
               when :nested_list then "Nest{ items: mkList() OR_ELSE RAISE }"
               when :nested_string_list then "StringNest{ items: mkStringList() OR_ELSE RAISE }"
               end
    <<~CHT
      #{pre}#{helper_list}
      FN maybe(flag: Bool) RETURNS !#{ty} ->
        IF flag THEN RETURN #{com_literal(p[:shape])}; END
        RAISE "no";
      END
      FN observe(x: #{ty}) RETURNS Int64 -> RETURN #{com_len_expr(p[:shape])}; END

      FN main() RETURNS !Void ->
        ASSERT observe(maybe(FALSE) OR_ELSE #{fallback}) >= 1_i64, "fallible call arg";
        RETURN;
      END
    CHT

  when :receiver_mutation
    append = case p[:shape]
             when :list then "v.append(2_i64);"
             when :string_list then 'v.append(COPY "z");'
             when :struct_string then 'v.name = v.name $+ COPY "d";'
             when :nested_list then "v.items.append(2_i64);"
             when :nested_string_list then 'v.items.append(COPY "z");'
             end
    assert_expr = case p[:shape]
                  when :list then "v.length()"
                  when :string_list then "v.length()"
                  when :struct_string then "v.name.length()"
                  when :nested_list then "v.items.length()"
                  when :nested_string_list then "v.items.length()"
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

  when :named_lifetime_return, :wildcard_lifetime_return
    lifetime = p[:mode] == :named_lifetime_return ? "x" : "*"
    <<~CHT
      FN borrow(x: String) RETURNS #{lifetime}:String -> RETURN x; END

      FN main() RETURNS Void ->
        s: String = COPY "abc";
        out: String = borrow(s);
        ASSERT out.length() == 3_i64, "call returned lifetime";
        RETURN;
      END
    CHT

  when :mutable_lifetime_plain
    <<~CHT
      FN borrow(MUTABLE x: String) RETURNS x:String -> RETURN x; END

      FN main() RETURNS Void ->
        MUTABLE s: String = COPY "abc";
        out: String = borrow(s);
        RETURN;
      END
    CHT

  when :mixed_atomic_return_lifetime
    <<~CHT
      STRUCT Counter { value: Int64 }
      FN spawn(MUTABLE c: Counter) RETURNS c:~Void
        REQUIRES c: ATOMIC | LOCKED ->
        RETURN BG { RETURN; };
      END

      FN main() RETURNS Void ->
        MUTABLE c = Counter{ value: 1_i64 } @indirect:atomic;
        h = spawn(c);
        NEXT h;
        RETURN;
      END
    CHT
  end
end
