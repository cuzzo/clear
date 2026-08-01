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
   :receiver_mutation, :bg_call].each do |mode|
    next if mode == :receiver_mutation && %i[string union_owned].include?(shape)
    CALL_OWNERSHIP_CELLS << { shape: shape, mode: mode }
  end
end

# Stream pipeline SELECT over OWNED items: the exact class that leaked one
# allocation per yielded element before the fused-consumer release fix.
# Dimensions: value shape x stream kind x selector ownership modality.
#   fn_observe / method_observe — selector borrows the item; the loop
#     releases the dequeued payload after the push/publish.
#   identity — `SELECT _` transfers ownership downstream (releasing too
#     would double-free).
#   move_ctor — GIVE moves the item into a struct; the transfer suppresses
#     the loop's release.
#   agg_sum — fused chained aggregate (observable SUM; INF folds via LIMIT).
CALL_OWNERSHIP_STREAM_KINDS = %i[open bounded inf].freeze
CALL_OWNERSHIP_STREAM_SELECTORS = %i[fn_observe method_observe identity move_ctor agg_sum].freeze

CALL_OWNERSHIP_VALUE_SHAPES.each do |shape|
  CALL_OWNERSHIP_STREAM_KINDS.each do |kind|
    CALL_OWNERSHIP_STREAM_SELECTORS.each do |selector|
      # Unions observe through PARTIAL MATCH (a statement), so their only
      # borrowing-selector spelling is the fn call; fn_observe covers it.
      next if selector == :method_observe && shape == :union_owned
      cell = { shape: shape, mode: :pipeline_call, stream_kind: kind, selector: selector }
      # [~INF]T rendezvous streams never drain; a MOVING selector could leave
      # moved payloads in flight at teardown (observed double-free), so the
      # annotator rejects the combination (INF_STREAM_SELECT_MOVES_ITEM).
      cell[:expected] = :compile_error if kind == :inf && selector == :move_ctor
      CALL_OWNERSHIP_CELLS << cell
    end
  end
end

# Retired `~?T[]` open-stream alias: the accept-then-leak compat path is
# closed; the parser rejects it with a migration diagnostic. One explicit
# rejection cell per shape whose alias spelling is expressible (list shapes
# would need a second [] dimension, which the alias never covered).
%i[string struct_string union_owned nested_list nested_string_list].each do |shape|
  CALL_OWNERSHIP_CELLS << { shape: shape, mode: :pipeline_retired_syntax, expected: :compile_error }
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
  when :list then "[List]Int64"
  when :string_list then "[List]String"
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
      UNION Val { Empty, Text: String, Items: [List]String }
      FN observeVal(x: Val) RETURNS Int64 ->
          PARTIAL MATCH x START
              Val.Text AS s -> RETURN s.length();,
              Val.Items AS items -> RETURN items.length();,
              DEFAULT -> RETURN 0_i64;
          END
      END
    CHT
  when :nested_list
    "STRUCT Nest { items: [List]Int64 }\n"
  when :nested_string_list
    "STRUCT StringNest { items: [List]String }\n"
  else
    ""
  end
end

def com_decl(shape, name = "v")
  case shape
  when :string then "#{name}: String = COPY \"abc\";"
  when :list then "MUTABLE #{name}: [List]Int64 = []; &#{name}.append(1_i64);"
  when :string_list then "#{name}: [List]String = mkStringList() OR_ELSE RAISE;"
  when :struct_string then "#{name}: Box = Box{ name: COPY \"abc\" };"
  when :union_owned then "#{name}: Val = Val{ Items: mkStringList() OR_ELSE RAISE };"
  when :nested_list then "MUTABLE inner: [List]Int64 = []; &inner.append(1_i64); #{name}: Nest = Nest{ items: inner };"
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

# ── Stream pipeline helpers ────────────────────────────────────────────────

# Inline-pivot item spelling used inside [~]/[~N]/[~INF] layers.
def com_stream_item_ty(shape)
  case shape
  when :list then "[List]Int64"
  when :string_list then "[List]String"
  else com_type(shape)
  end
end

# One owned item; every stream yields exactly two of these.
def com_stream_mk(shape)
  case shape
  when :string then 'COPY "ab"'
  when :list then "mkList() OR_ELSE RAISE"
  when :string_list then "mkStringList() OR_ELSE RAISE"
  when :struct_string then 'Box{ name: COPY "ab" }'
  when :union_owned then 'Val{ Text: COPY "ab" }'
  when :nested_list then "Nest{ items: mkList() OR_ELSE RAISE }"
  when :nested_string_list then "StringNest{ items: mkStringList() OR_ELSE RAISE }"
  end
end

# What com_len_expr yields for one com_stream_mk item.
def com_stream_per_item(shape)
  %i[string struct_string union_owned].include?(shape) ? 2 : 1
end

# Unions require an explicit BG STREAM item contract.
def com_stream_yields(shape)
  shape == :union_owned ? "YIELDS #{com_type(shape)} " : ""
end

def com_stream_decl(shape, kind)
  item_ty = com_stream_item_ty(shape)
  elem_ty = com_type(shape)
  mk = com_stream_mk(shape)
  case kind
  when :open
    <<~CHT
      src: [~]#{item_ty} = BG STREAM #{com_stream_yields(shape)}{
          x1: #{elem_ty} = #{mk};
          x2: #{elem_ty} = #{mk};
          YIELD x1;
          YIELD x2;
      };
    CHT
  when :bounded
    "src: [~2]#{item_ty} = [BG { mkItem() OR_ELSE RAISE; }, BG { mkItem() OR_ELSE RAISE; }];\n"
  when :inf
    <<~CHT
      src: [~INF]#{item_ty} = BG STREAM #{com_stream_yields(shape)}{
          WHILE TRUE DO
              x: #{elem_ty} = #{mk};
              YIELD x;
          END
      };
    CHT
  end
end

def com_stream_out_ty(kind, base)
  case kind
  when :open then "[~]#{base}"
  when :bounded then "[~2]#{base}"
  when :inf then "[~INF]#{base}"
  end
end

# Consume a re-streamed SELECT output: finite kinds drain with WHILE-EXISTS;
# INF takes exactly the two produced items via NEXT.
def com_stream_consume(kind, item_observe)
  if kind == :inf
    <<~CHT
      item1 = NEXT out;
      item2 = NEXT out;
      MUTABLE total = 0_i64;
      total = total + #{item_observe.call("item1")};
      total = total + #{item_observe.call("item2")};
    CHT
  else
    <<~CHT
      MUTABLE total = 0_i64;
      WHILE NEXT out EXISTS AS item DO
          total = total + #{item_observe.call("item")};
      END
    CHT
  end
end

FuzzGenerator.register(:call_ownership_contract_matrix, cells: CALL_OWNERSHIP_CELLS) do |p|
  ty = com_type(p[:shape])
  pre = com_prelude(p[:shape])
  helper_list = <<~CHT
    FN mkList() RETURNS ![List]Int64 ->
      MUTABLE xs: [List]Int64 = [];
      &xs.append(1_i64);
      RETURN xs;
    END

    FN mkStringList() RETURNS ![List]String ->
      MUTABLE xs: [List]String = List[];
      &xs.append(COPY "a");
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
               when :list then "(mkList() OR_ELSE RAISE)"
               when :string_list then "(mkStringList() OR_ELSE RAISE)"
               when :struct_string then 'Box{ name: COPY "fallback" }'
               when :union_owned then "Val{ Items: (mkStringList() OR_ELSE RAISE) }"
               when :nested_list then "Nest{ items: (mkList() OR_ELSE RAISE) }"
               when :nested_string_list then "StringNest{ items: (mkStringList() OR_ELSE RAISE) }"
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
               when :list then "(mkList() OR_ELSE RAISE)"
               when :string_list then "(mkStringList() OR_ELSE RAISE)"
               when :struct_string then 'Box{ name: COPY "fallback" }'
               when :union_owned then "Val{ Items: (mkStringList() OR_ELSE RAISE) }"
               when :nested_list then "Nest{ items: (mkList() OR_ELSE RAISE) }"
               when :nested_string_list then "StringNest{ items: (mkStringList() OR_ELSE RAISE) }"
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
             when :list then "&v.append(2_i64);"
             when :string_list then '&v.append(COPY "z");'
             when :struct_string then 'v.name = v.name $+ COPY "d";'
             when :nested_list then "&v.items.append(2_i64);"
             when :nested_string_list then '&v.items.append(COPY "z");'
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
    shape = p[:shape]
    kind = p[:stream_kind]
    selector = p[:selector]
    elem_ty = com_type(shape)
    expected = 2 * com_stream_per_item(shape)
    observe_fn = "FN observeItem(x: #{elem_ty}) RETURNS Int64 -> RETURN #{com_len_expr(shape)}; END\n"
    mk_item_fn = "FN mkItem() RETURNS !#{elem_ty} -> RETURN #{com_stream_mk(shape)}; END\n"
    method_expr = com_len_expr(shape, "_")
    stream_decl = com_stream_decl(shape, kind)

    pipeline_body = case selector
    when :fn_observe, :method_observe
      sel = selector == :fn_observe ? "observeItem(_)" : method_expr
      <<~CHT
        #{stream_decl}
        out: #{com_stream_out_ty(kind, "Int64")} = src |> SELECT #{sel};
        #{com_stream_consume(kind, ->(name) { name })}
      CHT
    when :identity
      <<~CHT
        #{stream_decl}
        out: #{com_stream_out_ty(kind, com_stream_item_ty(shape))} = src |> SELECT _;
        #{com_stream_consume(kind, ->(name) { com_len_expr(shape, name) })}
      CHT
    when :move_ctor
      <<~CHT
        #{stream_decl}
        out: #{com_stream_out_ty(kind, "Carrier")} = src |> SELECT Carrier{ v: GIVE _ };
        #{com_stream_consume(kind, ->(name) { com_len_expr(shape, "#{name}.v") })}
      CHT
    when :agg_sum
      if kind == :inf
        <<~CHT
          #{stream_decl}
          total: Int64 = src |> LIMIT 2 |> SELECT observeItem(_) |> SUM _;
        CHT
      else
        <<~CHT
          #{stream_decl}
          running: ~Int64@observable = src |> SELECT observeItem(_) |> SUM _;
          total = NEXT running;
        CHT
      end
    end

    carrier = selector == :move_ctor ? "STRUCT Carrier { v: #{elem_ty} }\n" : ""
    <<~CHT
      #{pre}#{carrier}#{helper_list}
      #{observe_fn}#{mk_item_fn}
      FN main() RETURNS !Void ->
        #{pipeline_body.lines.map { |l| l.strip.empty? ? l : "  #{l}" }.join}
        ASSERT total == #{expected}_i64, "stream pipeline ownership";
        RETURN;
      END
    CHT

  when :pipeline_retired_syntax
    <<~CHT
      #{pre}#{helper_list}
      FN main() RETURNS !Void ->
        src: ~?#{com_type(p[:shape])}[] = BG STREAM {
          x: #{com_type(p[:shape])} = #{com_stream_mk(p[:shape])};
          YIELD x;
        };
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
        MUTABLE c = Counter{ value: 1_i64 } @boxed:atomic;
        h = spawn(c);
        NEXT h;
        RETURN;
      END
    CHT
  end
end
