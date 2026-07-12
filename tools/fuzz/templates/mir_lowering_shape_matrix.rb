# Template: MIR lowering shape matrix.
#
# Covers ordinary source shapes that feed the highest-gap MIR lowering paths:
# list/hash literals, var declarations, returns, branch-local owned values,
# function calls, and loop-carried locals. The cells are intentionally positive
# source programs. If a cell fails, it is a surfaced compiler bug, not a fuzz
# harness exception.

MLSM_CELLS = []

%i[int string struct call_result].each do |element|
  %i[var_infer var_annotated return_direct fn_arg if_branch loop_assign].each do |context|
    MLSM_CELLS << { family: :list_lit, element: element, context: context }
  end
end

%i[int string struct].each do |value|
  %i[var_annotated return_direct fn_arg if_branch loop_assign].each do |context|
    MLSM_CELLS << { family: :hash_lit, value: value, context: context }
  end
end

%i[inferred annotated mutable reassign branch_init loop_init].each do |decl|
  %i[string list hash struct union optional_string].each do |shape|
    MLSM_CELLS << { family: :var_decl, decl: decl, shape: shape }
  end
end

%i[list hash string_concat struct_field union_payload or_fallback branch_return].each do |shape|
  MLSM_CELLS << { family: :return_shape, shape: shape }
end

%i[unary range copy_node move_node assert_stmt].each do |shape|
  MLSM_CELLS << { family: :node_dispatch, shape: shape }
end

def mlsm_list_type(element)
  case element
  when :string then "String[]"
  when :struct then "Item[]"
  else "Int64[]"
  end
end

def mlsm_list_literal(element)
  case element
  when :string then '[COPY "a", COPY "b", COPY "c"]'
  when :struct then '[]'
  when :call_result then '[make_num(), make_num() + 1_i64]'
  else '[1_i64, 2_i64, 3_i64]'
  end
end

def mlsm_list_prelude(element)
  case element
  when :struct
    "STRUCT Item { v: Int64 }\n"
  when :call_result
    "FN make_num() RETURNS Int64 ->\n    RETURN 4_i64;\nEND\n"
  else
    ""
  end
end

def mlsm_list_setup(element, name)
  type = mlsm_list_type(element)
  if element == :struct
    "MUTABLE #{name}: #{type} = [];\n    #{name}.append(Item{ v: 1_i64 });\n    #{name}.append(Item{ v: 2_i64 });"
  else
    "#{name}: #{type} = #{mlsm_list_literal(element)};"
  end
end

def mlsm_list_program(element, context)
  prelude = mlsm_list_prelude(element)
  type = mlsm_list_type(element)
  literal = mlsm_list_literal(element)

  case context
  when :var_infer
    <<~CHT
      #{prelude}FN main() RETURNS Void ->
          #{element == :struct ? mlsm_list_setup(element, "xs") : "xs = #{literal};"}
          ASSERT xs.length() == #{element == :struct ? 2 : (element == :call_result ? 2 : 3)}_i64, "list literal infer";
          RETURN;
      END
    CHT
  when :var_annotated
    <<~CHT
      #{prelude}FN main() RETURNS Void ->
          #{mlsm_list_setup(element, "xs")}
          ASSERT xs.length() == #{element == :struct ? 2 : (element == :call_result ? 2 : 3)}_i64, "list literal annotated";
          RETURN;
      END
    CHT
  when :return_direct
    build = element == :struct ? "MUTABLE xs: #{type} = [];\n    xs.append(Item{ v: 1_i64 });\n    xs.append(Item{ v: 2_i64 });\n    RETURN xs;" : "RETURN #{literal};"
    expected = element == :struct ? 2 : (element == :call_result ? 2 : 3)
    <<~CHT
      #{prelude}FN build() RETURNS !#{type} ->
          #{build}
      END

      FN main() RETURNS Void ->
          xs: #{type} = build() OR_ELSE RAISE;
          ASSERT xs.length() == #{expected}_i64, "list literal return";
          RETURN;
      END
    CHT
  when :fn_arg
    call_arg =
      if element == :struct
        "xs"
      else
        literal
      end
    pre_call = element == :struct ? "#{mlsm_list_setup(element, "xs")}\n    " : ""
    expected = element == :struct ? 2 : (element == :call_result ? 2 : 3)
    <<~CHT
      #{prelude}FN count(xs: #{type}) RETURNS Int64 ->
          RETURN xs.length();
      END

      FN main() RETURNS Void ->
          #{pre_call}ASSERT count(#{call_arg}) == #{expected}_i64, "list literal fn arg";
          RETURN;
      END
    CHT
  when :if_branch
    expected = element == :call_result ? 2 : 3
    <<~CHT
      #{prelude}FN main() RETURNS Void ->
          MUTABLE n: Int64 = 0_i64;
          IF TRUE THEN
              #{element == :struct ? mlsm_list_setup(element, "xs").gsub("\n", "\n        ") : "xs: #{type} = #{literal};"}
              n = xs.length();
          ELSE
              n = 99_i64;
          END
          ASSERT n == #{element == :struct ? 2 : expected}_i64, "list literal if branch";
          RETURN;
      END
    CHT
  when :loop_assign
    <<~CHT
      #{prelude}FN main() RETURNS Void ->
          MUTABLE i: Int64 = 0_i64;
          MUTABLE total: Int64 = 0_i64;
          WHILE i < 2_i64 DO
              #{element == :struct ? mlsm_list_setup(element, "xs").gsub("\n", "\n        ") : "xs: #{type} = #{literal};"}
              total = total + xs.length();
              i = i + 1_i64;
          END
          ASSERT total == #{(element == :struct ? 2 : (element == :call_result ? 2 : 3)) * 2}_i64, "list literal loop";
          RETURN;
      END
    CHT
  end
end

def mlsm_hash_type(value)
  case value
  when :string then "HashMap<String>"
  when :struct then "HashMap<Item>"
  else "HashMap<Int64>"
  end
end

def mlsm_hash_literal(value)
  case value
  when :string then '{"a": COPY "one", "b": COPY "two"}'
  when :struct then '{"a": Item{ v: 1_i64 }, "b": Item{ v: 2_i64 }}'
  else '{"a": 1_i64, "b": 2_i64}'
  end
end

def mlsm_hash_prelude(value)
  value == :struct ? "STRUCT Item { v: Int64 }\n" : ""
end

def mlsm_hash_program(value, context)
  prelude = mlsm_hash_prelude(value)
  type = mlsm_hash_type(value)
  literal = mlsm_hash_literal(value)

  case context
  when :var_annotated
    <<~CHT
      #{prelude}FN main() RETURNS Void ->
          m: #{type} = #{literal};
          ASSERT m.count() == 2_i64, "hash literal annotated";
          RETURN;
      END
    CHT
  when :return_direct
    <<~CHT
      #{prelude}FN build() RETURNS !#{type} ->
          RETURN #{literal};
      END

      FN main() RETURNS Void ->
          m: #{type} = build() OR_ELSE RAISE;
          ASSERT m.count() == 2_i64, "hash literal return";
          RETURN;
      END
    CHT
  when :fn_arg
    <<~CHT
      #{prelude}FN count(m: #{type}) RETURNS Int64 ->
          RETURN m.count();
      END

      FN main() RETURNS Void ->
          ASSERT count(#{literal}) == 2_i64, "hash literal fn arg";
          RETURN;
      END
    CHT
  when :if_branch
    <<~CHT
      #{prelude}FN main() RETURNS Void ->
          MUTABLE n: Int64 = 0_i64;
          IF TRUE THEN
              m: #{type} = #{literal};
              n = m.count();
          ELSE
              n = 99_i64;
          END
          ASSERT n == 2_i64, "hash literal if branch";
          RETURN;
      END
    CHT
  when :loop_assign
    <<~CHT
      #{prelude}FN main() RETURNS Void ->
          MUTABLE i: Int64 = 0_i64;
          MUTABLE total: Int64 = 0_i64;
          WHILE i < 2_i64 DO
              m: #{type} = #{literal};
              total = total + m.count();
              i = i + 1_i64;
          END
          ASSERT total == 4_i64, "hash literal loop";
          RETURN;
      END
    CHT
  end
end

def mlsm_shape_spec(shape)
  case shape
  when :string
    ["", "String", 'COPY "hello"', "x.length()", "5_i64"]
  when :list
    ["", "Int64[]", "[1_i64, 2_i64]", "x.length()", "2_i64"]
  when :hash
    ["", "HashMap<Int64>", '{"a": 1_i64, "b": 2_i64}', "x.count()", "2_i64"]
  when :struct
    ["STRUCT Item { name: String }\n", "Item", 'Item{ name: COPY "item" }', "x.name.length()", "4_i64"]
  when :union
    ["UNION Slot { Empty, Name: String }\n", "Slot", 'Slot{ Name: COPY "union" }', "1_i64", "1_i64"]
  when :optional_string
    ["", "?String", 'COPY "maybe"', "1_i64", "1_i64"]
  end
end

def mlsm_var_decl_program(decl, shape)
  prelude, type, expr, observe, expected = mlsm_shape_spec(shape)

  case decl
  when :inferred
    <<~CHT
      #{prelude}FN main() RETURNS Void ->
          x = #{expr};
          ASSERT #{observe} == #{expected}, "var decl inferred";
          RETURN;
      END
    CHT
  when :annotated
    <<~CHT
      #{prelude}FN main() RETURNS Void ->
          x: #{type} = #{expr};
          ASSERT #{observe} == #{expected}, "var decl annotated";
          RETURN;
      END
    CHT
  when :mutable
    <<~CHT
      #{prelude}FN main() RETURNS Void ->
          MUTABLE x: #{type} = #{expr};
          ASSERT #{observe} == #{expected}, "var decl mutable";
          RETURN;
      END
    CHT
  when :reassign
    second_expr = shape == :optional_string ? 'COPY "later"' : expr
    <<~CHT
      #{prelude}FN main() RETURNS Void ->
          MUTABLE x: #{type} = #{expr};
          x = #{second_expr};
          ASSERT #{observe} == #{expected}, "var decl reassign";
          RETURN;
      END
    CHT
  when :branch_init
    <<~CHT
      #{prelude}FN main() RETURNS Void ->
          MUTABLE n: Int64 = 0_i64;
          IF TRUE THEN
              x: #{type} = #{expr};
              n = #{observe == "1_i64" ? observe : observe.sub(/\Ax\./, "x.")};
          ELSE
              n = 99_i64;
          END
          ASSERT n == #{expected}, "var decl branch";
          RETURN;
      END
    CHT
  when :loop_init
    <<~CHT
      #{prelude}FN main() RETURNS Void ->
          MUTABLE i: Int64 = 0_i64;
          MUTABLE total: Int64 = 0_i64;
          WHILE i < 2_i64 DO
              x: #{type} = #{expr};
              total = total + #{observe};
              i = i + 1_i64;
          END
          ASSERT total == #{expected.sub("_i64", "").to_i * 2}_i64, "var decl loop";
          RETURN;
      END
    CHT
  end
end

def mlsm_return_program(shape)
  case shape
  when :list
    <<~CHT
      FN build() RETURNS !Int64[] ->
          RETURN [1_i64, 2_i64, 3_i64];
      END

      FN main() RETURNS Void ->
          xs = build() OR_ELSE RAISE;
          ASSERT xs.length() == 3_i64, "return list shape";
          RETURN;
      END
    CHT
  when :hash
    <<~CHT
      FN build() RETURNS !HashMap<Int64> ->
          RETURN {"a": 1_i64, "b": 2_i64};
      END

      FN main() RETURNS Void ->
          m = build() OR_ELSE RAISE;
          ASSERT m.count() == 2_i64, "return hash shape";
          RETURN;
      END
    CHT
  when :string_concat
    <<~CHT
      FN build() RETURNS String ->
          RETURN COPY "a" $+ COPY "b";
      END

      FN main() RETURNS Void ->
          s = build();
          ASSERT s == "ab", "return string concat";
          RETURN;
      END
    CHT
  when :struct_field
    <<~CHT
      STRUCT Box { value: String }

      FN build() RETURNS String ->
          b: Box = Box{ value: COPY "field" };
          RETURN b.value;
      END

      FN main() RETURNS Void ->
          s = build();
          ASSERT s == "field", "return struct field";
          RETURN;
      END
    CHT
  when :union_payload
    <<~CHT
      UNION Box { Empty, Text: String }

      FN build() RETURNS Box ->
          RETURN Box{ Text: COPY "payload" };
      END

      FN main() RETURNS Void ->
          _ = build();
          RETURN;
      END
    CHT
  when :or_fallback
    <<~CHT
      FN maybe(flag: Bool) RETURNS !String ->
          IF flag THEN
              RETURN COPY "ok";
          END
          RAISE "nope";
      END

      FN build() RETURNS String ->
          RETURN maybe(FALSE) OR_ELSE COPY "fallback";
      END

      FN main() RETURNS Void ->
          s = build();
          ASSERT s == "fallback", "return or fallback";
          RETURN;
      END
    CHT
  when :branch_return
    <<~CHT
      FN build(flag: Bool) RETURNS String ->
          IF flag THEN
              RETURN COPY "left";
          ELSE
              RETURN COPY "right";
          END
      END

      FN main() RETURNS Void ->
          s = build(FALSE);
          ASSERT s == "right", "return branch";
          RETURN;
      END
    CHT
  end
end

def mlsm_node_dispatch_program(shape)
  case shape
  when :unary
    <<~CHT
      FN main() RETURNS Void ->
          x: Int64 = -1_i64;
          ASSERT x == -1_i64, "unary lowering";
          RETURN;
      END
    CHT
  when :range
    <<~CHT
      FN main() RETURNS Void ->
          MUTABLE total: Int64 = 0_i64;
          FOR i IN (1_i64 ..= 3_i64) DO
              total = total + i;
          END
          ASSERT total == 6_i64, "range lowering";
          RETURN;
      END
    CHT
  when :copy_node
    <<~CHT
      FN main() RETURNS Void ->
          s: String = COPY "abc";
          t: String = COPY s;
          ASSERT t.length() == 3_i64, "copy lowering";
          RETURN;
      END
    CHT
  when :move_node
    <<~CHT
      FN consume(TAKES s: String) RETURNS Int64 -> RETURN s.length(); END

      FN main() RETURNS Void ->
          s: String = COPY "abc";
          ASSERT consume(GIVE s) == 3_i64, "move lowering";
          RETURN;
      END
    CHT
  when :assert_stmt
    <<~CHT
      FN main() RETURNS Void ->
          ASSERT TRUE, "assert lowering";
          RETURN;
      END
    CHT
  end
end

FuzzGenerator.register(:mir_lowering_shape_matrix, cells: MLSM_CELLS) do |p|
  case p[:family]
  when :list_lit
    mlsm_list_program(p.fetch(:element), p.fetch(:context))
  when :hash_lit
    mlsm_hash_program(p.fetch(:value), p.fetch(:context))
  when :var_decl
    mlsm_var_decl_program(p.fetch(:decl), p.fetch(:shape))
  when :return_shape
    mlsm_return_program(p.fetch(:shape))
  when :node_dispatch
    mlsm_node_dispatch_program(p.fetch(:shape))
  end
end
